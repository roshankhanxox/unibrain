// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ShadowBrainHook} from "../src/ShadowBrainHook.sol";
import {ShadowBrainHub} from "../src/ShadowBrainHub.sol";
import {IShadowBrainHub} from "../src/IShadowBrainHub.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

contract MockTarget {
    uint256 public counter;
    uint256 public lastValue;

    event FunctionCalled(uint256 value);

    function automatedFunction(uint256 value) external payable {
        counter++;
        lastValue = value;
        emit FunctionCalled(value);
    }

    receive() external payable {}
}

contract TestShadowBrainHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    ShadowBrainHook hook;
    ShadowBrainHub hub;
    MockTarget target;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;

    uint256 constant AUCTION_INTERVAL = 30 minutes;
    uint256 constant AUCTION_DURATION = 5 minutes;
    int256 constant START_DISCOUNT = -100; // Start with -1% (user pays more)
    int256 constant DISCOUNT_DECREMENT = 50; // Improve by 0.5% every interval
    uint256 constant DECREMENT_INTERVAL = 30 seconds;

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy hub and target
        hub = new ShadowBrainHub();
        target = new MockTarget();

        // Calculate hook address using the same pattern as other tests
        // Note: Removed BEFORE_SWAP_RETURNS_DELTA_FLAG to fix currency settlement issues
        address hookAddress = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG
            )
        );

        // Deploy hook using deployCodeTo
        deployCodeTo(
            "ShadowBrainHook.sol",
            abi.encode(address(manager), address(hub)),
            hookAddress
        );
        hook = ShadowBrainHook(hookAddress);

        // Configure hub
        hub.setShadowBrainHook(address(hook));

        // Register automated call
        bytes memory callData = abi.encodeWithSelector(
            MockTarget.automatedFunction.selector,
            42
        );
        hub.registerCall(address(target), callData, 0);

        // Initialize pool with hook
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        // Initialize pool
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Configure the hook after initialization
        hook.configurePool(
            poolKey,
            AUCTION_INTERVAL,
            AUCTION_DURATION,
            START_DISCOUNT,
            DISCOUNT_DECREMENT,
            DECREMENT_INTERVAL
        );

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function testHookDeployment() public view {
        assertEq(address(hook.shadowBrainHub()), address(hub));
        assertEq(hub.shadowBrainHook(), address(hook));
    }

    function testAutomatedCallRegistration() public view {
        IShadowBrainHub.AutomatedCall memory call = hub.getCall(0);
        assertEq(call.target, address(target));
        assertTrue(call.enabled);
    }

    function testDutchAuctionDiscount() public {
        // Get initial discount (should be negative/penalty)
        int256 discount = hook.getCurrentDiscount(poolKey);
        assertEq(discount, START_DISCOUNT);

        // Fast forward time to see discount improve
        vm.warp(block.timestamp + DECREMENT_INTERVAL);
        discount = hook.getCurrentDiscount(poolKey);
        assertEq(discount, START_DISCOUNT + DISCOUNT_DECREMENT);

        // Fast forward more
        vm.warp(block.timestamp + DECREMENT_INTERVAL * 3);
        discount = hook.getCurrentDiscount(poolKey);
        assertEq(discount, START_DISCOUNT + DISCOUNT_DECREMENT * 4);
    }

    function testSwapTriggersExecution() public {
        uint256 counterBefore = target.counter();

        // Perform swap using the same pattern as other tests
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Check that the automated function was called
        assertEq(target.counter(), counterBefore + 1);
        assertEq(target.lastValue(), 42);
    }

    function testAuctionCycle() public {
        uint256 initialCounter = target.counter();

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // First swap triggers execution
        SwapParams memory params1 = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap(poolKey, params1, testSettings, ZERO_BYTES);
        assertEq(target.counter(), initialCounter + 1);

        // Immediate second swap shouldn't trigger (still in same auction)
        SwapParams memory params2 = SwapParams({
            zeroForOne: false,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(poolKey, params2, testSettings, ZERO_BYTES);
        assertEq(target.counter(), initialCounter + 1);

        // Fast forward past auction interval
        vm.warp(block.timestamp + AUCTION_INTERVAL + 1);

        // Next swap should trigger new execution
        swapRouter.swap(poolKey, params1, testSettings, ZERO_BYTES);
        assertEq(target.counter(), initialCounter + 2);
    }

    function testDisableAutomatedCall() public {
        // Disable the call
        hub.updateCall(0, false);

        uint256 counterBefore = target.counter();

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Swap should not trigger execution
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        assertEq(target.counter(), counterBefore);
    }

    function testMultipleAutomatedCalls() public {
        // Register a second call
        MockTarget target2 = new MockTarget();
        bytes memory callData2 = abi.encodeWithSelector(
            MockTarget.automatedFunction.selector,
            100
        );
        hub.registerCall(address(target2), callData2, 0);

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Perform swap
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Both targets should be called
        assertEq(target.lastValue(), 42);
        assertEq(target2.lastValue(), 100);
    }

    function testAuctionOutsideDuration() public {
        // Fast forward past auction duration but within interval
        vm.warp(block.timestamp + AUCTION_DURATION + 1 minutes);

        // Discount should be 0 (no auction active)
        int256 discount = hook.getCurrentDiscount(poolKey);
        assertEq(discount, 0);

        uint256 counterBefore = target.counter();

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Swap should not trigger execution
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        assertEq(target.counter(), counterBefore);
    }

    function testSetAuctionActive() public {
        // Disable auction
        hook.setAuctionActive(poolKey, false);

        uint256 counterBefore = target.counter();

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Swap should not trigger execution
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        assertEq(target.counter(), counterBefore);

        // Re-enable auction
        hook.setAuctionActive(poolKey, true);

        // Swap should now trigger execution
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        assertEq(target.counter(), counterBefore + 1);
    }

    function testOnlyOwnerCanConfigure() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        hook.configurePool(poolKey, 1 hours, 10 minutes, -200, 100, 1 minutes);
    }

    function testOnlyHookCanExecuteCalls() public {
        vm.prank(address(0xdead));
        vm.expectRevert("Only hook can call");
        hub.executeCalls();
    }
}
