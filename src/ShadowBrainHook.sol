// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IShadowBrainHub} from "./IShadowBrainHub.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

contract ShadowBrainHook is BaseHook, Ownable {
    using SafeCast for uint256;

    struct DutchAuctionConfig {
        uint256 startTime;
        uint256 interval;
        uint256 duration;
        int256 startDiscount;
        int256 discountDecrement;
        uint256 decrementInterval;
        bool active;
    }

    struct PoolConfig {
        DutchAuctionConfig auctionConfig;
        uint256 lastExecutionTime;
    }

    IShadowBrainHub public immutable shadowBrainHub;
    mapping(bytes32 => PoolConfig) public poolConfigs;

    event AuctionStarted(bytes32 indexed poolId, uint256 startTime);
    event AuctionExecuted(
        bytes32 indexed poolId,
        uint256 executionTime,
        int256 discount
    );
    event PoolConfigured(
        bytes32 indexed poolId,
        uint256 interval,
        uint256 duration
    );

    error AuctionNotActive();
    error InvalidInterval();
    error InvalidDuration();

    constructor(
        IPoolManager _poolManager,
        IShadowBrainHub _shadowBrainHub
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        shadowBrainHub = _shadowBrainHub;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false, // Changed to false - we're not modifying swap amounts
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override returns (bytes4) {
        // Pool configuration needs to be done manually via configurePool function
        // since hookData is not available in afterInitialize
        return IHooks.afterInitialize.selector;
    }

    function configurePool(
        PoolKey memory key,
        uint256 interval,
        uint256 duration,
        int256 startDiscount,
        int256 discountDecrement,
        uint256 decrementInterval
    ) external onlyOwner {
        _configurePool(
            key,
            interval,
            duration,
            startDiscount,
            discountDecrement,
            decrementInterval
        );
    }

    function _configurePool(
        PoolKey memory key,
        uint256 interval,
        uint256 duration,
        int256 startDiscount,
        int256 discountDecrement,
        uint256 decrementInterval
    ) internal {
        if (interval == 0) revert InvalidInterval();
        if (duration == 0 || duration > interval) revert InvalidDuration();

        bytes32 poolId = _getPoolId(key);

        poolConfigs[poolId] = PoolConfig({
            auctionConfig: DutchAuctionConfig({
                startTime: block.timestamp,
                interval: interval,
                duration: duration,
                startDiscount: startDiscount,
                discountDecrement: discountDecrement,
                decrementInterval: decrementInterval,
                active: true
            }),
            lastExecutionTime: block.timestamp
        });

        emit PoolConfigured(poolId, interval, duration);
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        bytes32 poolId = _getPoolId(key);
        PoolConfig storage config = poolConfigs[poolId];

        if (!config.auctionConfig.active) {
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        // Check if it's time for a new auction
        uint256 timeSinceLastExecution = block.timestamp -
            config.lastExecutionTime;
        if (timeSinceLastExecution >= config.auctionConfig.interval) {
            _startNewAuction(poolId, config);
        }

        // For now, we're not modifying swap amounts - just tracking the auction state
        // The discount calculation is available via getCurrentDiscount() for external use
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        bytes32 poolId = _getPoolId(key);
        PoolConfig storage config = poolConfigs[poolId];

        if (!config.auctionConfig.active) {
            return (IHooks.afterSwap.selector, 0);
        }

        // Check if we're in an active auction period
        uint256 timeSinceStart = block.timestamp -
            config.auctionConfig.startTime;
        uint256 auctionCycle = timeSinceStart % config.auctionConfig.interval;

        if (auctionCycle <= config.auctionConfig.duration) {
            // Execute the automated calls
            shadowBrainHub.executeCalls();
            config.lastExecutionTime = block.timestamp;

            emit AuctionExecuted(
                poolId,
                block.timestamp,
                _calculateDiscount(config)
            );
        }

        return (IHooks.afterSwap.selector, 0);
    }

    function _startNewAuction(
        bytes32 poolId,
        PoolConfig storage config
    ) internal {
        config.auctionConfig.startTime = block.timestamp;
        emit AuctionStarted(poolId, block.timestamp);
    }

    function _calculateDiscount(
        PoolConfig memory config
    ) internal view returns (int256) {
        if (!config.auctionConfig.active) return 0;

        uint256 timeSinceStart = block.timestamp -
            config.auctionConfig.startTime;
        uint256 auctionCycle = timeSinceStart % config.auctionConfig.interval;

        // If we're outside the auction duration, no discount
        if (auctionCycle > config.auctionConfig.duration) {
            return 0;
        }

        // Calculate discount based on time elapsed in auction
        uint256 steps = auctionCycle / config.auctionConfig.decrementInterval;
        int256 discount = config.auctionConfig.startDiscount +
            (config.auctionConfig.discountDecrement * int256(steps));

        return discount;
    }

    function _getPoolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function getCurrentDiscount(
        PoolKey memory key
    ) external view returns (int256) {
        bytes32 poolId = _getPoolId(key);
        return _calculateDiscount(poolConfigs[poolId]);
    }

    function setAuctionActive(
        PoolKey memory key,
        bool active
    ) external onlyOwner {
        bytes32 poolId = _getPoolId(key);
        poolConfigs[poolId].auctionConfig.active = active;
    }
}
// pragma solidity ^0.8.26;

// import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {IHooks} from "v4-core/interfaces/IHooks.sol";
// import {Hooks} from "v4-core/libraries/Hooks.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
// import {BeforeSwapDelta, BeforeSwapDeltaLibrary,toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
// import {IShadowBrainHub} from "./IShadowBrainHub.sol";
// import {Currency} from "v4-core/types/Currency.sol";
// import {SafeCast} from "v4-core/libraries/SafeCast.sol";
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// import {SwapParams} from "v4-core/types/PoolOperation.sol";

// contract ShadowBrainHook is BaseHook, Ownable {
//     using SafeCast for uint256;

//     struct DutchAuctionConfig {
//         uint256 startTime;
//         uint256 interval;
//         uint256 duration;
//         int256 startDiscount;
//         int256 discountDecrement;
//         uint256 decrementInterval;
//         bool active;
//     }

//     struct PoolConfig {
//         DutchAuctionConfig auctionConfig;
//         uint256 lastExecutionTime;
//     }

//     IShadowBrainHub public immutable shadowBrainHub;
//     mapping(bytes32 => PoolConfig) public poolConfigs;

//     event AuctionStarted(bytes32 indexed poolId, uint256 startTime);
//     event AuctionExecuted(
//         bytes32 indexed poolId,
//         uint256 executionTime,
//         int256 discount
//     );
//     event PoolConfigured(
//         bytes32 indexed poolId,
//         uint256 interval,
//         uint256 duration
//     );

//     error AuctionNotActive();
//     error InvalidInterval();
//     error InvalidDuration();

//     constructor(
//         IPoolManager _poolManager,
//         IShadowBrainHub _shadowBrainHub
//     ) BaseHook(_poolManager) Ownable(msg.sender) {
//         shadowBrainHub = _shadowBrainHub;
//     }

//     function getHookPermissions()
//         public
//         pure
//         override
//         returns (Hooks.Permissions memory)
//     {
//         return
//             Hooks.Permissions({
//                 beforeInitialize: false,
//                 afterInitialize: true,
//                 beforeAddLiquidity: false,
//                 beforeRemoveLiquidity: false,
//                 afterAddLiquidity: false,
//                 afterRemoveLiquidity: false,
//                 beforeSwap: true,
//                 afterSwap: true,
//                 beforeDonate: false,
//                 afterDonate: false,
//                 beforeSwapReturnDelta: true,
//                 afterSwapReturnDelta: false,
//                 afterAddLiquidityReturnDelta: false,
//                 afterRemoveLiquidityReturnDelta: false
//             });
//     }

//     function _afterInitialize(
//         address,
//         PoolKey calldata key,
//         uint160,
//         int24
//     ) internal override returns (bytes4) {
//         // Pool configuration needs to be done manually via configurePool function
//         // since hookData is not available in afterInitialize
//         return IHooks.afterInitialize.selector;
//     }

//     function configurePool(
//         PoolKey memory key,
//         uint256 interval,
//         uint256 duration,
//         int256 startDiscount,
//         int256 discountDecrement,
//         uint256 decrementInterval
//     ) external onlyOwner {
//         _configurePool(
//             key,
//             interval,
//             duration,
//             startDiscount,
//             discountDecrement,
//             decrementInterval
//         );
//     }

//     function _configurePool(
//         PoolKey memory key,
//         uint256 interval,
//         uint256 duration,
//         int256 startDiscount,
//         int256 discountDecrement,
//         uint256 decrementInterval
//     ) internal {
//         if (interval == 0) revert InvalidInterval();
//         if (duration == 0 || duration > interval) revert InvalidDuration();

//         bytes32 poolId = _getPoolId(key);

//         poolConfigs[poolId] = PoolConfig({
//             auctionConfig: DutchAuctionConfig({
//                 startTime: block.timestamp,
//                 interval: interval,
//                 duration: duration,
//                 startDiscount: startDiscount,
//                 discountDecrement: discountDecrement,
//                 decrementInterval: decrementInterval,
//                 active: true
//             }),
//             lastExecutionTime: block.timestamp
//         });

//         emit PoolConfigured(poolId, interval, duration);
//     }

//     function _beforeSwap(
//         address,
//         PoolKey calldata key,
//         SwapParams calldata params,
//         bytes calldata
//     ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
//         bytes32 poolId = _getPoolId(key);
//         PoolConfig storage config = poolConfigs[poolId];

//         if (!config.auctionConfig.active) {
//             return (
//                 IHooks.beforeSwap.selector,
//                 BeforeSwapDeltaLibrary.ZERO_DELTA,
//                 0
//             );
//         }

//         // Check if it's time for a new auction
//         uint256 timeSinceLastExecution = block.timestamp -
//             config.lastExecutionTime;
//         if (timeSinceLastExecution >= config.auctionConfig.interval) {
//             _startNewAuction(poolId, config);
//         }

//         // Calculate current discount based on Dutch Auction
//         int256 discount = _calculateDiscount(config);

//         // Apply discount to swap amount
//         BeforeSwapDelta delta = BeforeSwapDeltaLibrary.ZERO_DELTA;
//         if (discount != 0) {
//             // Calculate the discount amount based on swap direction
//             uint256 amountToDiscount = uint256(
//                 params.amountSpecified > 0
//                     ? params.amountSpecified
//                     : -params.amountSpecified
//             );

//             uint256 discountAmount = (amountToDiscount *
//                 uint256(discount > 0 ? discount : -discount)) / 10000;

//             if (params.zeroForOne) {
//                 // Swapping token0 for token1, give bonus token1
//                 // Create delta with specified=0, unspecified=-discountAmount
//                 delta = toBeforeSwapDelta(
//                     0,
//                     -discountAmount.toInt128()
//                 );
//             } else {
//                 // Swapping token1 for token0, give bonus token0
//                 // Create delta with specified=-discountAmount, unspecified=0
//                 delta = toBeforeSwapDelta(
//                     -discountAmount.toInt128(),
//                     0
//                 );
//             }
//         }

//         return (IHooks.beforeSwap.selector, delta, 0);
//     }

//     function _afterSwap(
//         address,
//         PoolKey calldata key,
//         SwapParams calldata params,
//         BalanceDelta,
//         bytes calldata
//     ) internal override returns (bytes4, int128) {
//         bytes32 poolId = _getPoolId(key);
//         PoolConfig storage config = poolConfigs[poolId];

//         if (!config.auctionConfig.active) {
//             return (IHooks.afterSwap.selector, 0);
//         }

//         // Check if we're in an active auction period
//         uint256 timeSinceStart = block.timestamp -
//             config.auctionConfig.startTime;
//         uint256 auctionCycle = timeSinceStart % config.auctionConfig.interval;

//         if (auctionCycle <= config.auctionConfig.duration) {
//             // Execute the automated calls
//             shadowBrainHub.executeCalls();
//             config.lastExecutionTime = block.timestamp;

//             emit AuctionExecuted(
//                 poolId,
//                 block.timestamp,
//                 _calculateDiscount(config)
//             );
//         }

//         return (IHooks.afterSwap.selector, 0);
//     }

//     function _startNewAuction(
//         bytes32 poolId,
//         PoolConfig storage config
//     ) internal {
//         config.auctionConfig.startTime = block.timestamp;
//         emit AuctionStarted(poolId, block.timestamp);
//     }

//     function _calculateDiscount(
//         PoolConfig memory config
//     ) internal view returns (int256) {
//         if (!config.auctionConfig.active) return 0;

//         uint256 timeSinceStart = block.timestamp -
//             config.auctionConfig.startTime;
//         uint256 auctionCycle = timeSinceStart % config.auctionConfig.interval;

//         // If we're outside the auction duration, no discount
//         if (auctionCycle > config.auctionConfig.duration) {
//             return 0;
//         }

//         // Calculate discount based on time elapsed in auction
//         uint256 steps = auctionCycle / config.auctionConfig.decrementInterval;
//         int256 discount = config.auctionConfig.startDiscount +
//             (config.auctionConfig.discountDecrement * int256(steps));

//         return discount;
//     }

//     function _getPoolId(PoolKey memory key) internal pure returns (bytes32) {
//         return keccak256(abi.encode(key));
//     }

//     function getCurrentDiscount(
//         PoolKey memory key
//     ) external view returns (int256) {
//         bytes32 poolId = _getPoolId(key);
//         return _calculateDiscount(poolConfigs[poolId]);
//     }

//     function setAuctionActive(
//         PoolKey memory key,
//         bool active
//     ) external onlyOwner {
//         bytes32 poolId = _getPoolId(key);
//         poolConfigs[poolId].auctionConfig.active = active;
//     }
// }
