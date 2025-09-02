// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IShadowBrainHub} from "./IShadowBrainHub.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ShadowBrainHub is IShadowBrainHub, Ownable {
    mapping(uint256 => AutomatedCall) public automatedCalls;
    uint256 public nextCallId;
    address public shadowBrainHook;

    modifier onlyHook() {
        require(msg.sender == shadowBrainHook, "Only hook can call");
        _;
    }

    constructor() Ownable(msg.sender) {}

    function setShadowBrainHook(address _hook) external onlyOwner {
        shadowBrainHook = _hook;
    }

    function registerCall(
        address target,
        bytes calldata data,
        uint256 value
    ) external onlyOwner returns (uint256) {
        uint256 callId = nextCallId++;
        automatedCalls[callId] = AutomatedCall({
            target: target,
            data: data,
            value: value,
            enabled: true
        });

        emit CallRegistered(callId, target);
        return callId;
    }

    function updateCall(uint256 callId, bool enabled) external onlyOwner {
        require(automatedCalls[callId].target != address(0), "Call not found");
        automatedCalls[callId].enabled = enabled;
        emit CallUpdated(callId, enabled);
    }

    function executeCalls() external onlyHook {
        for (uint256 i = 0; i < nextCallId; i++) {
            AutomatedCall memory call = automatedCalls[i];
            if (call.enabled && call.target != address(0)) {
                (bool success, ) = call.target.call{value: call.value}(
                    call.data
                );
                emit CallExecuted(i, call.target, success);
            }
        }
    }

    function getCall(
        uint256 callId
    ) external view returns (AutomatedCall memory) {
        return automatedCalls[callId];
    }

    receive() external payable {}
}
