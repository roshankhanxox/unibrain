// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ShadowBrainVault} from "./ShadowBrainVault.sol";
import {IShadowBrainHub} from "./IShadowBrainHub.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";


/// @title ShadowBrainHook - Uniswap v4 Hook implementing Dutch Auctions
contract ShadowBrainHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    // Auction configuration
    struct AuctionConfig {
        int256 startDiscount; // Starting discount in basis points (negative = penalty)
        int256 reserveDiscount; // Reserve discount in basis points (positive = bonus)
        uint256 decayRate; // Rate of change per second (basis points)
        uint256 duration; // Total auction duration in seconds
    }

    // Auction state per pool
    struct AuctionState {
        bool active;
        uint256 startTime;
        AuctionConfig config;
    }

    // State variables
    ShadowBrainVault public immutable vault;
    IShadowBrainHub public hub;
    mapping(PoolId => AuctionState) public auctions;
    mapping(PoolId => uint256) public lastExecution;

    // Configuration
    uint256 public constant AUCTION_INTERVAL = 30 minutes;
    uint256 public constant BASIS_POINTS = 10000;

    // Default auction config
    AuctionConfig public defaultConfig =
        AuctionConfig({
            startDiscount: -1000, // -10%
            reserveDiscount: 800, // +8%
            decayRate: 30, // 0.3% per second (reaches 0 at ~33 seconds, +8% at 30 minutes)
            duration: 1800 // 30 minutes
        });

    // Events
    event AuctionStarted(PoolId indexed poolId, uint256 startTime);
    event AuctionEnded(PoolId indexed poolId, uint256 endTime);
    event SwapWithPenalty(
        PoolId indexed poolId,
        address indexed user,
        uint256 penalty
    );
    event SwapWithBonus(
        PoolId indexed poolId,
        address indexed user,
        uint256 bonus
    );

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        vault = new ShadowBrainVault();
    }

    /// @notice Hook permissions
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeSwap: true,
                afterSwap: true,
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /// @notice Before swap hook - applies auction pricing
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        // Check if auction should start
        if (
            !auctions[poolId].active &&
            block.timestamp >= lastExecution[poolId] + AUCTION_INTERVAL
        ) {
            _startAuction(poolId);
        }

        // If no active auction, proceed normally
        if (!auctions[poolId].active) {
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        // Calculate current discount
        int256 currentDiscount = getCurrentDiscount(poolId);

        // Apply discount/penalty
        return _applyAuctionPricing(key, params, currentDiscount, sender);
    }

    /// @notice After swap hook - triggers auction end if profitable
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();

        if (auctions[poolId].active) {
            int256 currentDiscount = getCurrentDiscount(poolId);

            // If discount is positive (profitable), end the auction
            if (currentDiscount > 0) {
                _endAuction(poolId);
                // trigger automated operations
                if (address(hub) != address(0)) {
                    // best-effort trigger; do not revert if hub errors
                    try hub.executeCalls() {
                    } catch {}
                }
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice Get current discount for a pool (public getter)
    function getCurrentDiscount(PoolId poolId) public view returns (int256) {
        AuctionState memory auction = auctions[poolId];

        if (!auction.active) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - auction.startTime;

        // If auction duration exceeded, return reserve discount
        if (timeElapsed >= auction.config.duration) {
            return auction.config.reserveDiscount;
        }

        // Calculate linear decay: startDiscount + (decayRate * timeElapsed)
        int256 decay = int256(auction.config.decayRate * timeElapsed);
        int256 currentDiscount = auction.config.startDiscount + decay;

        // Cap at reserve discount
        if (currentDiscount > auction.config.reserveDiscount) {
            return auction.config.reserveDiscount;
        }

        return currentDiscount;
    }

    /// @notice Get swap quote showing current pricing
    function getSwapQuote(
        PoolKey calldata key,
        uint256 amountIn,
        bool zeroForOne
    )
        external
        view
        returns (
            uint256 amountOut,
            int256 currentDiscount,
            bool shouldWait,
            uint256 timeUntilProfitable
        )
    {
        PoolId poolId = key.toId();
        currentDiscount = getCurrentDiscount(poolId);

        // Calculate base amount (simplified - would use actual pool math in production)
        amountOut = amountIn; // 1:1 for simplicity

        // Apply discount
        if (currentDiscount < 0) {
            // Penalty - user gets less
            uint256 penalty = (amountIn * uint256(-currentDiscount)) /
                BASIS_POINTS;
            amountOut = amountIn - penalty;
            shouldWait = true;

            // Calculate time until profitable (when discount reaches 0)
            if (auctions[poolId].active) {
                AuctionState memory auction = auctions[poolId];
                uint256 timeElapsed = block.timestamp - auction.startTime;
                uint256 timeToBreakeven = uint256(
                    -auction.config.startDiscount
                ) / auction.config.decayRate;

                if (timeElapsed < timeToBreakeven) {
                    timeUntilProfitable = timeToBreakeven - timeElapsed;
                }
            }
        } else if (currentDiscount > 0) {
            // Bonus - user gets more
            uint256 bonus = (amountIn * uint256(currentDiscount)) /
                BASIS_POINTS;
            amountOut = amountIn + bonus;
            shouldWait = false;
            timeUntilProfitable = 0;
        }
    }

    /// @notice Start new auction
    function _startAuction(PoolId poolId) private {
        auctions[poolId] = AuctionState({
            active: true,
            startTime: block.timestamp,
            config: defaultConfig
        });

        emit AuctionStarted(poolId, block.timestamp);
    }

    /// @notice End auction
    function _endAuction(PoolId poolId) private {
        auctions[poolId].active = false;
        lastExecution[poolId] = block.timestamp;

        emit AuctionEnded(poolId, block.timestamp);
    }

    /// @notice Apply auction pricing to swap
    function _applyAuctionPricing(
        PoolKey calldata key,
        SwapParams calldata params,
        int256 currentDiscount,
        address sender
    ) private returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amountSpecified = uint256(
            params.amountSpecified > 0
                ? params.amountSpecified
                : -params.amountSpecified
        );

        if (currentDiscount < 0) {
            // Apply penalty
            return _applyPenalty(key, amountSpecified, currentDiscount, sender, params);
        } else if (currentDiscount > 0) {
            // Apply bonus
            return _applyBonus(key, amountSpecified, currentDiscount, sender, params);
        }

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /// @notice Apply penalty (take from user)
    function _applyPenalty(
        PoolKey calldata key,
        uint256 amountSpecified,
        int256 currentDiscount,
        address sender,
        SwapParams calldata params
    ) private returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 penaltyAmount = (amountSpecified * uint256(-currentDiscount)) /
            BASIS_POINTS;

        // Determine specified/unspecified currencies for this swap
        (Currency specified, ) = _sortCurrencies(key, params);

        // Take penalty from PoolManager to the vault; sender will settle more input to the manager
        specified.take(poolManager, address(vault), penaltyAmount, false);
        vault.storePenalty(Currency.unwrap(specified), penaltyAmount);

        // Hook reports a positive specified delta equal to what it took
        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(penaltyAmount)), 0);

        emit SwapWithPenalty(key.toId(), sender, penaltyAmount);

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    /// @notice Apply bonus (give to user)
    function _applyBonus(
        PoolKey calldata key,
        uint256 amountSpecified,
        int256 currentDiscount,
        address sender,
        SwapParams calldata params
    ) private returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 bonusAmount = (amountSpecified * uint256(currentDiscount)) /
            BASIS_POINTS;

        // Determine specified/unspecified currencies for this swap
        (, Currency unspecified) = _sortCurrencies(key, params);

        address outputToken = Currency.unwrap(unspecified);

        // Check if vault has enough funds
        if (vault.getAvailableBalance(outputToken) >= bonusAmount) {
            // Settle bonus into PoolManager from the vault so manager can pay extra output
            // Requires the vault to have approved the hook to transferFrom
            unspecified.settle(poolManager, address(vault), bonusAmount, false);
            // Reduce vault reserves to reflect consumption
            vault.consumeBonus(outputToken, bonusAmount);

            // Report a negative unspecified delta (hook paid manager)
            BeforeSwapDelta delta = toBeforeSwapDelta(0, -int128(int256(bonusAmount)));

            emit SwapWithBonus(key.toId(), sender, bonusAmount);

            return (BaseHook.beforeSwap.selector, delta, 0);
        }

        // Not enough funds, proceed without bonus
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _sortCurrencies(
        PoolKey calldata key,
        SwapParams calldata params
    ) internal pure returns (Currency specified, Currency unspecified) {
        (specified, unspecified) = (params.zeroForOne == (params.amountSpecified < 0))
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);
    }

    /// @notice Update auction configuration (owner only)
    function updateDefaultConfig(AuctionConfig calldata newConfig) external {
        // In production, add proper access control
        defaultConfig = newConfig;
    }

    /// @notice Set ShadowBrainHub address (owner-only in production)
    function setHub(address hubAddress) external {
        hub = IShadowBrainHub(hubAddress);
    }

    /// @notice Manual auction start (for testing)
    function manualStartAuction(PoolId poolId) external {
        _startAuction(poolId);
    }

    /// @notice Get vault address
    function getVault() external view returns (address) {
        return address(vault);
    }
}
