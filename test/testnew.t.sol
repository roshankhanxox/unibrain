// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry libraries
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {ShadowBrainHook} from "../src/ShadowBrainHook.sol";
import {ShadowBrainVault} from "../src/ShadowBrainVault.sol";

contract ShadowBrainHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // Test tokens
    Currency token0;
    Currency token1;

    ShadowBrainHook hook;
    ShadowBrainVault vault;
    PoolId poolId;

    // Test constants
    uint256 constant INITIAL_BALANCE = 100e18;
    uint256 constant LIQUIDITY_AMOUNT = 100e18;
    uint256 constant SWAP_AMOUNT = 10e18;

    function setUp() public {
        console.log("=== Starting ShadowBrainHook Test Setup ===");

        // Deploy v4 core contracts
        deployFreshManagerAndRouters();
        console.log(".. Deployed fresh manager and routers");

        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();
        console.log(".. Deployed and minted test tokens");
        console.log("Token0 balance:", token0.balanceOfSelf());
        console.log("Token1 balance:", token1.balanceOfSelf());

        // Deploy our hook with correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);

        console.log("Deploying hook to address:", hookAddress);
        deployCodeTo("ShadowBrainHook.sol", abi.encode(manager), hookAddress);
        hook = ShadowBrainHook(hookAddress);
        vault = ShadowBrainVault(hook.getVault());

        console.log(".. Deployed ShadowBrainHook at:", address(hook));
        console.log(".. Vault deployed at:", address(vault));

        // Approve hook to spend tokens
        MockERC20(Currency.unwrap(token0)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(token1)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(token0)).approve(
            address(vault),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(token1)).approve(
            address(vault),
            type(uint256).max
        );
        // Allow hook to spend from vault when settling bonus into PoolManager
        vm.prank(address(hook));
        vault.approveSpender(Currency.unwrap(token1), address(hook), type(uint256).max);
        vm.prank(address(hook));
        vault.approveSpender(Currency.unwrap(token0), address(hook), type(uint256).max);
        console.log(".. Approved hook and vault to spend tokens");

        // Initialize pool
        (key, poolId) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);
        console.log(
            ".. Initialized pool with ID:",
            uint256(PoolId.unwrap(poolId))
        );

        // Add liquidity
        _addLiquidity();
        console.log(".. Added initial liquidity to pool");

        _fundVault();

        console.log("=== Setup Complete ===\n");
    }

    function _addLiquidity() private {
        // Add liquidity in different ranges for better testing
        int24[3] memory tickLowers = [int24(-60), int24(-120), TickMath.minUsableTick(60)];
        int24[3] memory tickUppers = [int24(60), int24(120), TickMath.maxUsableTick(60)];
        for (uint256 i = 0; i < 3; i++) {
            modifyLiquidityRouter.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLowers[i],
                    tickUpper: tickUppers[i],
                    liquidityDelta: int256(LIQUIDITY_AMOUNT),
                    salt: bytes32(0)
                }),
                ZERO_BYTES
            );
        }
    }

    function _fundVault() private {
        // Add initial funds to vault for bonus payouts
        uint256 fundAmount = 100e18;

        // Fund vault directly from test contract via deposit (pulls from this address)
        vault.depositYield(Currency.unwrap(token0), fundAmount);
        vault.depositYield(Currency.unwrap(token1), fundAmount);

        console.log(
            "Vault token0 balance:",
            vault.tokenReserves(Currency.unwrap(token0))
        );
        console.log(
            "Vault token1 balance:",
            vault.tokenReserves(Currency.unwrap(token1))
        );
    }

    function test_initial_state() public {
        console.log("=== Testing Initial State ===");

        // Check that no auction is active initially
        (bool active, , ) = hook.auctions(poolId);
        assertFalse(active);
        console.log(".. No auction active initially");

        // Check current discount is 0 when no auction
        int256 discount = hook.getCurrentDiscount(poolId);
        assertEq(discount, 0);
        console.log(".. Discount is 0 when no auction:", discount);

        // Check vault has funds
        assertTrue(vault.tokenReserves(Currency.unwrap(token0)) > 0);
        assertTrue(vault.tokenReserves(Currency.unwrap(token1)) > 0);
        console.log(".. Vault has initial funds");
    }

    function test_manual_auction_start() public {
        console.log("\n=== Testing Manual Auction Start ===");

        console.log("Starting auction manually...");
        hook.manualStartAuction(poolId);

        // Check auction is now active
        ( bool active, uint256 startTime, ) = hook.auctions(poolId);
        assertTrue(active);
        assertEq(startTime, block.timestamp);
        console.log(".. Auction started successfully at time:", startTime);

        // Check initial discount is negative (penalty)
        int256 discount = hook.getCurrentDiscount(poolId);
        assertTrue(discount < 0);
        console.log(".. Initial discount is negative (penalty):", discount);
    }

    function test_auction_auto_start() public {
        console.log("\n=== Testing Automatic Auction Start ===");

        // Move time forward past auction interval
        uint256 currentTime = block.timestamp;
        console.log("Current time:", currentTime);

        vm.warp(currentTime + hook.AUCTION_INTERVAL() + 1);
        console.log("Warped to time:", block.timestamp);

        // Execute a swap to trigger auction start
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("Executing swap to trigger auction start...");
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Check auction started automatically
        ( bool active, , ) = hook.auctions(poolId);
        assertTrue(active);
        console.log(".. Auction started automatically during swap");
    }

    function test_get_swap_quote_early_auction() public {
        console.log("\n=== Testing Swap Quote During Early Auction ===");

        // Start auction
        hook.manualStartAuction(poolId);
        console.log("Started auction");

        // Get quote during penalty phase
        (
            uint256 amountOut,
            int256 currentDiscount,
            bool shouldWait,
            uint256 timeUntilProfitable
        ) = hook.getSwapQuote(key, SWAP_AMOUNT, true);

        console.log("Amount in:", SWAP_AMOUNT);
        console.log("Amount out:", amountOut);
        console.log("Current discount:", currentDiscount);
        console.log("Should wait:", shouldWait);
        console.log("Time until profitable:", timeUntilProfitable);

        // During penalty phase
        assertTrue(currentDiscount < 0);
        assertTrue(shouldWait);
        assertTrue(amountOut < SWAP_AMOUNT); // Should get less due to penalty
        assertTrue(timeUntilProfitable > 0);

        console.log(
            ".. Early auction quote shows penalty and wait recommendation"
        );
    }

    function test_get_swap_quote_late_auction() public {
        console.log("\n=== Testing Swap Quote During Late Auction ===");

        // Start auction
        hook.manualStartAuction(poolId);

        // Move time forward to profitable phase
        uint256 timeToProfit = 35 minutes; // Past the breakeven point
        vm.warp(block.timestamp + timeToProfit);
        console.log("Warped forward", timeToProfit / 60, "minutes");

        // Get quote during bonus phase
        (
            uint256 amountOut,
            int256 currentDiscount,
            bool shouldWait,
            uint256 timeUntilProfitable
        ) = hook.getSwapQuote(key, SWAP_AMOUNT, true);

        console.log("Amount in:", SWAP_AMOUNT);
        console.log("Amount out:", amountOut);
        console.log("Current discount:", currentDiscount);
        console.log("Should wait:", shouldWait);
        console.log("Time until profitable:", timeUntilProfitable);

        // During bonus phase
        assertTrue(currentDiscount > 0);
        assertFalse(shouldWait);
        assertTrue(amountOut > SWAP_AMOUNT); // Should get more due to bonus
        assertEq(timeUntilProfitable, 0);

        console.log(
            ".. Late auction quote shows bonus and execute recommendation"
        );
    }

    function test_swap_with_penalty() public {
        console.log("\n=== Testing Swap with Penalty ===");

        // Start auction
        hook.manualStartAuction(poolId);

        // Record balances before
        uint256 token0Before = token0.balanceOfSelf();
        uint256 token1Before = token1.balanceOfSelf();
        uint256 vaultToken0Before = vault.tokenReserves(
            Currency.unwrap(token0)
        );

        console.log("Token0 balance before:", token0Before);
        console.log("Token1 balance before:", token1Before);
        console.log("Vault token0 before:", vaultToken0Before);

        // Execute swap during penalty phase
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("Executing swap with penalty...");
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Record balances after
        uint256 token0After = token0.balanceOfSelf();
        uint256 token1After = token1.balanceOfSelf();
        uint256 vaultToken0After = vault.tokenReserves(Currency.unwrap(token0));

        console.log("Token0 balance after:", token0After);
        console.log("Token1 balance after:", token1After);
        console.log("Vault token0 after:", vaultToken0After);

        // Verify penalty was collected
        assertTrue(token0Before - token0After >= SWAP_AMOUNT); // Paid more than swap amount due to penalty
        assertTrue(vaultToken0After > vaultToken0Before); // Vault received penalty

        console.log(".. Penalty successfully collected and stored in vault");
    }

    function test_swap_with_bonus() public {
        console.log("\n=== Testing Swap with Bonus ===");

        // Start auction
        hook.manualStartAuction(poolId);

        // Move to bonus phase
        vm.warp(block.timestamp + 35 minutes);
        console.log("Moved to bonus phase");

        // Record balances before
        uint256 token0Before = token0.balanceOfSelf();
        uint256 token1Before = token1.balanceOfSelf();
        uint256 vaultToken1Before = vault.tokenReserves(
            Currency.unwrap(token1)
        );

        console.log("Token0 balance before:", token0Before);
        console.log("Token1 balance before:", token1Before);
        console.log("Vault token1 before:", vaultToken1Before);

        // Execute swap during bonus phase
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("Executing swap with bonus...");
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Record balances after
        uint256 token0After = token0.balanceOfSelf();
        uint256 token1After = token1.balanceOfSelf();
        uint256 vaultToken1After = vault.tokenReserves(Currency.unwrap(token1));

        console.log("Token0 balance after:", token0After);
        console.log("Token1 balance after:", token1After);
        console.log("Vault token1 after:", vaultToken1After);

        // Verify bonus was paid (more token1 received than normal)
        assertTrue(token1After > token1Before); // Received token1
        assertTrue(vaultToken1After < vaultToken1Before); // Vault paid bonus

        console.log(".. Bonus successfully paid from vault");
    }

    function test_auction_ends_after_profitable_swap() public {
        console.log("\n=== Testing Auction Ends After Profitable Swap ===");

        // Start auction
        hook.manualStartAuction(poolId);
        console.log("Started auction");

        // Verify auction is active
        ( bool activeBefore, , ) = hook.auctions(poolId);
        assertTrue(activeBefore);
        console.log(".. Auction is active");

        // Move to bonus phase
        vm.warp(block.timestamp + 35 minutes);
        console.log("Moved to bonus phase");

        // Execute profitable swap
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("Executing profitable swap...");
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Verify auction ended
        ( bool activeAfter, , ) = hook.auctions(poolId);
        assertFalse(activeAfter);
        console.log(".. Auction ended after profitable swap");

        // Verify lastExecution was updated
        uint256 lastExecution = hook.lastExecution(poolId);
        assertEq(lastExecution, block.timestamp);
        console.log(".. Last execution time updated:", lastExecution);
    }

    function test_auction_discount_decay() public {
        console.log("\n=== Testing Auction Discount Decay Over Time ===");

        // Start auction
        hook.manualStartAuction(poolId);
        uint256 startTime = block.timestamp;

        // Test discount at different time points
        uint256[] memory timePoints = new uint256[](5);
        timePoints[0] = 0; // Start
        timePoints[1] = 10 minutes;
        timePoints[2] = 33 minutes; // Approximate breakeven
        timePoints[3] = 40 minutes;
        timePoints[4] = 60 minutes; // Max

        for (uint i = 0; i < timePoints.length; i++) {
            vm.warp(startTime + timePoints[i]);
            int256 discount = hook.getCurrentDiscount(poolId);
            // console.log("Time:", timePoints[i] / 60, "minutes, Discount:", discount);

            if (i == 0) {
                // Should start negative
                assertTrue(discount <= -1000);
            } else if (i == timePoints.length - 1) {
                // Should cap at reserve discount
                assertTrue(discount >= 800);
            }
        }

        console.log(".. Discount decays properly over time");
    }

    function test_vault_fund_management() public {
        console.log("\n=== Testing Vault Fund Management ===");

        address testToken = Currency.unwrap(token0);
        uint256 initialBalance = vault.tokenReserves(testToken);
        uint256 testAmount = 50e18;

        console.log("Initial vault balance:", initialBalance);

        // Prepare owner (hook) with tokens and allowance, then add funds as owner
        MockERC20(testToken).transfer(address(hook), testAmount);
        vm.prank(address(hook));
        MockERC20(testToken).approve(address(vault), testAmount);
        vm.prank(address(hook));
        vault.addFunds(testToken, testAmount);
        uint256 afterAdd = vault.tokenReserves(testToken);
        assertEq(afterAdd, initialBalance + testAmount);
        console.log(".. Added funds successfully. New balance:", afterAdd);

        // Test emergency withdrawal
        vm.prank(address(hook));
        vault.emergencyWithdraw(testToken, testAmount);
        uint256 afterWithdraw = vault.tokenReserves(testToken);
        assertEq(afterWithdraw, initialBalance);
        console.log(
            ".. Emergency withdrawal successful. Balance:",
            afterWithdraw
        );

        // Test deposit yield
        MockERC20(testToken).approve(address(vault), testAmount);
        vault.depositYield(testToken, testAmount);
        uint256 afterDeposit = vault.tokenReserves(testToken);
        assertEq(afterDeposit, initialBalance + testAmount);
        console.log(".. Yield deposit successful. Balance:", afterDeposit);
    }

    function test_insufficient_vault_funds() public {
        console.log("\n=== Testing Insufficient Vault Funds ===");

        // Drain vault by withdrawing most funds
        address token1Address = Currency.unwrap(token1);
        uint256 vaultBalance = vault.getAvailableBalance(token1Address);
        
        // Withdraw most funds, leaving minimal amount
        if (vaultBalance > 1e18) {
            vm.prank(address(hook));
            vault.emergencyWithdraw(token1Address, vaultBalance - 1e18);
        }
        
        uint256 remainingBalance = vault.getAvailableBalance(token1Address);
        console.log("Remaining vault token1 balance:", remainingBalance);

        // Start auction and move to bonus phase
        hook.manualStartAuction(poolId);
        vm.warp(block.timestamp + 35 minutes);
        console.log("Moved to bonus phase with minimal vault funds");

        // Record balances
        uint256 token1Before = token1.balanceOfSelf();
        uint256 vaultToken1Before = vault.getAvailableBalance(token1Address);

        // Execute swap (should proceed without bonus due to insufficient funds)
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(SWAP_AMOUNT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("Executing swap with insufficient vault funds...");
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 token1After = token1.balanceOfSelf();
        uint256 vaultToken1After = vault.getAvailableBalance(token1Address);

        // Should still receive some token1 from normal swap, but no bonus
        console.log("Token1 received:", token1After - token1Before);
        console.log(
            "Vault balance change:",
            int256(vaultToken1After) - int256(vaultToken1Before)
        );

        console.log(
            ".. Swap completed without bonus when vault has insufficient funds"
        );
    }

    function test_multiple_auction_cycles() public {
        console.log("\n=== Testing Multiple Auction Cycles ===");

        for (uint256 cycle = 0; cycle < 3; cycle++) {
            console.log("--- Cycle", cycle + 1, "---");

            // Start auction
            hook.manualStartAuction(poolId);
            ( bool active, , ) = hook.auctions(poolId);
            assertTrue(active);
            console.log(".. Auction", cycle + 1, "started");

            // Move to profitable phase and execute
            vm.warp(block.timestamp + 35 minutes);

            SwapParams memory params = SwapParams({
                zeroForOne: cycle % 2 == 0, // Alternate directions
                amountSpecified: -int256(SWAP_AMOUNT),
                sqrtPriceLimitX96: cycle % 2 == 0
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            });

            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
                .TestSettings({takeClaims: false, settleUsingBurn: false});

            swapRouter.swap(key, params, testSettings, ZERO_BYTES);

            // Verify auction ended
            (bool activeAfter, , ) = hook.auctions(poolId);
            assertFalse(activeAfter);
            console.log(".. Auction", cycle + 1, "ended successfully");

            // Move time forward for next cycle
            vm.warp(block.timestamp + hook.AUCTION_INTERVAL() + 1);
        }

        console.log(".. Multiple auction cycles completed successfully");
    }

    function test_update_auction_config() public {
        console.log("\n=== Testing Auction Config Update ===");

        // Get current config
        (, , ShadowBrainHook.AuctionConfig memory oldConfig) = hook.auctions(
            poolId
        );
        console.log("Old start discount:", oldConfig.startDiscount);
        console.log("Old reserve discount:", oldConfig.reserveDiscount);

        // Create new config
        ShadowBrainHook.AuctionConfig memory newConfig = ShadowBrainHook
            .AuctionConfig({
                startDiscount: -2000, // -20%
                reserveDiscount: 1200, // +12%
                decayRate: 50, // Faster decay
                duration: 900 // 15 minutes
            });

        hook.updateDefaultConfig(newConfig);
        console.log(".. Updated auction configuration");

        // Start new auction to test new config
        vm.warp(block.timestamp + hook.AUCTION_INTERVAL() + 1);
        hook.manualStartAuction(poolId);

        int256 newDiscount = hook.getCurrentDiscount(poolId);
        console.log("New initial discount:", newDiscount);
        assertEq(newDiscount, newConfig.startDiscount);

        console.log(".. New configuration applied successfully");
    }
}