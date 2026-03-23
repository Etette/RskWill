// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IRNSResolver {
    function addr(bytes32 nameHash) external view returns (address);
}

interface IRNSRegistry {
    function resolver(bytes32 nameHash) external view returns (address);
}

// RIF Relay trusted forwarder
interface IForwarder {
    struct ForwardRequest {
        address from;
        address to;
        uint256 value;
        uint256 gas;
        uint256 nonce;
        bytes data;
    }

    function verify(ForwardRequest calldata req, bytes calldata sig) external view returns (bool);
}

interface IRskWill {
    event WillCreated(address indexed owner, uint256 heartbeatInterval, uint256 cooldownPeriod);
    event Deposited(address indexed owner, address indexed asset, uint256 amount);
    event Withdrawn(address indexed owner, address indexed asset, uint256 amount);
    event StillAlive(address indexed owner, uint256 newDeadline);
    event HeartbeatUpdated(address indexed owner, uint256 newInterval);
    event BeneficiaryAdded(address indexed owner, address indexed asset, address indexed beneficiary, uint256 bps);
    event BeneficiaryRemoved(address indexed owner, address indexed asset, address indexed beneficiary);
    event ClaimInitiated(address indexed owner, address indexed initiator, uint256 claimInitiatedAt);
    event ClaimCancelled(address indexed owner);
    event WillDistributed(address indexed owner);
    event AssetDistributed(address indexed owner, address indexed asset, address indexed beneficiary, uint256 amount);

    error WillAlreadyExists();
    error WillDoesNotExist();
    error WillNotActive();
    error WillNotClaiming();
    error WillAlreadySettled();
    error NotABeneficiary();
    error HeartbeatStillRunning();
    error CooldownNotOver();
    error BelowMinimumHeartbeat();
    error BelowMinimumCooldown();
    error ZeroAmount();
    error ZeroAddress();
    error AllocationMismatch();
    error AssetAlreadyConfigured();
    error BeneficiaryAlreadyAdded();
    error BeneficiaryNotFound();
    error RNSResolutionFailed();
    error TransferFailed();
    error InsufficientBalance();
    error InvalidForwarder();
}
