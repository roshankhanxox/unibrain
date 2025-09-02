// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IShadowBrainHub {
    struct AutomatedCall {
        address target;
        bytes data;
        uint256 value;
        bool enabled;
    }

    event CallExecuted(uint256 indexed callId, address indexed target, bool success);
    event CallRegistered(uint256 indexed callId, address indexed target);
    event CallUpdated(uint256 indexed callId, bool enabled);

    function registerCall(address target, bytes calldata data, uint256 value) external returns (uint256);
    function updateCall(uint256 callId, bool enabled) external;
    function executeCalls() external;
    function getCall(uint256 callId) external view returns (AutomatedCall memory);
}
