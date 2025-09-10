// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IShadowBrainHub {
    struct AutomatedCall {
        address target;
        bytes callData;
        uint256 value;
        bool enabled;
    }

    function setShadowBrainHook(address hook) external;
    function shadowBrainHook() external view returns (address);

    function registerCall(address target, bytes calldata callData, uint256 value) external returns (uint256 id);
    function updateCall(uint256 id, bool enabled) external;
    function getCall(uint256 id) external view returns (AutomatedCall memory);
    function callsCount() external view returns (uint256);

    function executeCalls() external;
}


