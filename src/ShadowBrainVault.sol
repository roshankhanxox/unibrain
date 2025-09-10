// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ShadowBrainVault - Manages funds for bonus payouts and penalty collection
contract ShadowBrainVault {
    using SafeERC20 for IERC20;

    address public immutable hook;
    address public owner;
    
    // Token reserves in the vault
    mapping(address => uint256) public tokenReserves;
    
    // Events
    event YieldDeposited(address indexed token, uint256 amount);
    event BonusPaid(address indexed token, uint256 amount, address indexed recipient);
    event PenaltyCollected(address indexed token, uint256 amount);
    
    modifier onlyHook() {
        require(msg.sender == hook, "Only hook can call");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call");
        _;
    }
    
    constructor() {
        hook = msg.sender;
        owner = msg.sender;
    }
    
    /// @notice Deposit yield/profits to vault
    function depositYield(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        tokenReserves[token] += amount;
        emit YieldDeposited(token, amount);
    }
    
    /// @notice Pay bonus to user (called by hook)
    function payBonus(address token, uint256 amount, address recipient) external onlyHook {
        require(tokenReserves[token] >= amount, "Insufficient vault balance");
        tokenReserves[token] -= amount;
        IERC20(token).safeTransfer(recipient, amount);
        emit BonusPaid(token, amount, recipient);
    }
    
    /// @notice Store penalty collected from user (called by hook)
    function storePenalty(address token, uint256 amount) external onlyHook {
        tokenReserves[token] += amount;
        emit PenaltyCollected(token, amount);
    }

    /// @notice Consume funds for bonus payout via PoolManager settlement (called by hook)
    function consumeBonus(address token, uint256 amount) external onlyHook {
        require(tokenReserves[token] >= amount, "Insufficient vault balance");
        tokenReserves[token] -= amount;
    }
    
    /// @notice Check available balance for bonuses
    function getAvailableBalance(address token) external view returns (uint256) {
        return tokenReserves[token];
    }
    
    /// @notice Owner can add initial funds for bootstrapping
    function addFunds(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        tokenReserves[token] += amount;
    }
    
    /// @notice Emergency withdrawal (owner only)
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(tokenReserves[token] >= amount, "Insufficient balance");
        tokenReserves[token] -= amount;
        IERC20(token).safeTransfer(owner, amount);
    }

    /// @notice Approve a spender to move vault's tokens (owner only)
    function approveSpender(address token, address spender, uint256 amount) external onlyOwner {
        IERC20(token).approve(spender, amount);
    }
}