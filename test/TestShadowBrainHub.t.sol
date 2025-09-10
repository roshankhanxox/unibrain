// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {ShadowBrainHook} from "../src/ShadowBrainHook.sol";
import {ShadowBrainHub} from "../src/ShadowBrainHub.sol";
import {IShadowBrainHub} from "../src/IShadowBrainHub.sol";

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

contract TestShadowBrainHub is Test, Deployers {
    using CurrencyLibrary for Currency;

    ShadowBrainHook hook;
    ShadowBrainHub hub;
    MockTarget target1;
    MockTarget target2;

    using PoolIdLibrary for PoolKey;
    PoolSwapTest.TestSettings settings;

    function setUp() public {
        // v4 setup
        deployFreshManagerAndRouters();
        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();

        // Hook deploy to address with required flags
        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        deployCodeTo("ShadowBrainHook.sol", abi.encode(manager), hookAddress);
        hook = ShadowBrainHook(hookAddress);

        // Hub
        hub = new ShadowBrainHub();
        hub.setShadowBrainHook(address(hook));
        hook.setHub(address(hub));

        // Targets
        target1 = new MockTarget();
        target2 = new MockTarget();

        // Register calls
        bytes memory call1 = abi.encodeWithSelector(MockTarget.automatedFunction.selector, 42);
        bytes memory call2 = abi.encodeWithSelector(MockTarget.automatedFunction.selector, 99);
        hub.registerCall(address(target1), call1, 0);
        hub.registerCall(address(target2), call2, 0);

        // Pool
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: hook});
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(10 ether), salt: bytes32(0)}),
            ZERO_BYTES
        );

        settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function _triggerProfitableSwap() internal {
        // Start auction and warp to profitable phase
        hook.manualStartAuction(key.toId());
        vm.warp(block.timestamp + 35 minutes);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        swapRouter.swap(key, params, settings, ZERO_BYTES);
    }

    function test_executeCallsOnProfit() public {
        uint256 beforeCount = hub.totalCallsExecuted();
        uint256 c1 = target1.counter();
        uint256 c2 = target2.counter();

        _triggerProfitableSwap();

        assertEq(hub.totalCallsExecuted(), beforeCount + 2);
        assertEq(target1.counter(), c1 + 1);
        assertEq(target1.lastValue(), 42);
        assertEq(target2.counter(), c2 + 1);
        assertEq(target2.lastValue(), 99);
    }

    function test_disableCall() public {
        // disable second call
        hub.updateCall(1, false);
        uint256 beforeCount = hub.totalCallsExecuted();

        _triggerProfitableSwap();

        // Only one executed
        assertEq(hub.totalCallsExecuted(), beforeCount + 1);
        assertEq(target1.counter(), 1);
        assertEq(target2.counter(), 0);
    }
}
