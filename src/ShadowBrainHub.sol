// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IShadowBrainHub} from "./IShadowBrainHub.sol";

contract ShadowBrainHub is IShadowBrainHub {
    address public override shadowBrainHook;
    address public owner;

    AutomatedCall[] private _calls;

    // Counter for executed calls (successful low-level calls)
    uint256 public totalCallsExecuted;

    event CallExecuted(address indexed target, uint256 value);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyHook() {
        require(msg.sender == shadowBrainHook, "Only hook can call");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setShadowBrainHook(address hook) external override onlyOwner {
        shadowBrainHook = hook;
    }

    function registerCall(address target, bytes calldata callData, uint256 value)
        external
        override
        onlyOwner
        returns (uint256 id)
    {
        _calls.push(AutomatedCall({target: target, callData: callData, value: value, enabled: true}));
        return _calls.length - 1;
    }

    function updateCall(uint256 id, bool enabled) external override onlyOwner {
        require(id < _calls.length, "Invalid id");
        _calls[id].enabled = enabled;
    }

    function getCall(uint256 id) external view override returns (AutomatedCall memory) {
        require(id < _calls.length, "Invalid id");
        return _calls[id];
    }

    function callsCount() external view override returns (uint256) {
        return _calls.length;
    }

    function executeCalls() external override onlyHook {
        for (uint256 i = 0; i < _calls.length; i++) {
            AutomatedCall memory c = _calls[i];
            if (!c.enabled) continue;
            (bool ok, ) = c.target.call{value: c.value}(c.callData);
            require(ok, "Call failed");
            unchecked {
                totalCallsExecuted += 1;
            }
            emit CallExecuted(c.target, c.value);
        }
    }

    receive() external payable {}
}


