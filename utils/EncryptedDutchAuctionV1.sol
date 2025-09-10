// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal on-chain CoFHE system contract interface.
/// Implementations should evaluate an encrypted program with inputs (eTau, eEps, bucketIndex, ctx),
/// return an opaque handle immediately, and later allow checking readiness and decrypting a result.
interface IFhenixCoFHE {
    function requestEval(
        bytes calldata eTau,
        bytes calldata eEps,
        uint256 bucketIndex,
        bytes calldata ctx
    ) external returns (bytes32 handle);

    function isReady(bytes32 handle) external view returns (bool);

    /// @notice Decrypt the result for a handle; returns discount in basis points.
    function decrypt(bytes32 handle) external returns (int256 resultBp);
}

/// @title EncryptedDutchAuctionV1
/// @notice Fully on-chain, bucketed, CoFHE-backed Dutch auction coordinator.
/// - Swap value increases over time (no bids)
/// - Randomness is introduced via encrypted time-shift (tau) and slope tweak (epsilon)
/// - No external keepers: progression occurs during calls (e.g., hook.beforeSwap)
contract EncryptedDutchAuctionV1 {
    struct ConfigPublic {
        int256 startDiscountBp;      // e.g., -1000
        int256 reserveDiscountBp;    // e.g., +800
        int256 decayRatePubBpPerSec; // e.g., 30
        uint32 durationSec;          // e.g., 1800
        uint32 bucketSeconds;        // e.g., 10
    }

    struct EncryptedParams {
        bytes eTau; // encrypted time-shift τ
        bytes eEps; // encrypted slope-perturbation ε
    }

    struct AuctionState {
        bool active;
        uint64 startTime;
        int256 lastDiscountBp;
        uint64 lastUpdatedBucket;
        ConfigPublic cfg;
        EncryptedParams enc;
    }

    address public owner;
    IFhenixCoFHE public cofhe;

    // Optional tip (in wei) paid to the caller who finalizes a new bucket.
    uint256 public keeperTipWei;

    // Pool identity is an arbitrary bytes32 selected by the integrator (e.g., keccak256(abi.encode(key, address(hook))))
    mapping(bytes32 => AuctionState) public auctions;
    mapping(bytes32 => mapping(uint256 => bytes32)) public bucketHandle; // poolId -> bucketIndex -> handle

    event CoFHEUpdated(address cofhe);
    event KeeperTipUpdated(uint256 tipWei);
    event AuctionStarted(bytes32 indexed poolId, uint64 startTime);
    event AuctionEnded(bytes32 indexed poolId, uint64 endTime);
    event BucketRequested(bytes32 indexed poolId, uint256 bucket, bytes32 handle);
    event BucketFinalized(bytes32 indexed poolId, uint256 bucket, int256 discountBp);

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor(address _cofhe) {
        owner = msg.sender;
        cofhe = IFhenixCoFHE(_cofhe);
        emit CoFHEUpdated(_cofhe);
    }

    receive() external payable {}

    function setCoFHE(address _cofhe) external onlyOwner {
        cofhe = IFhenixCoFHE(_cofhe);
        emit CoFHEUpdated(_cofhe);
    }

    function setKeeperTip(uint256 tipWei) external onlyOwner {
        keeperTipWei = tipWei;
        emit KeeperTipUpdated(tipWei);
    }

    /// @notice Set encrypted params for the next/ongoing auction cycle for a given poolId.
    function setEncryptedParams(bytes32 poolId, bytes calldata eTau, bytes calldata eEps) external onlyOwner {
        auctions[poolId].enc = EncryptedParams({ eTau: eTau, eEps: eEps });
    }

    /// @notice Start a new auction cycle for a pool.
    function startAuction(bytes32 poolId, ConfigPublic calldata cfg) external onlyOwner {
        require(cfg.bucketSeconds > 0 && cfg.durationSec >= cfg.bucketSeconds, "bad cfg");
        AuctionState storage s = auctions[poolId];
        s.active = true;
        s.startTime = uint64(block.timestamp);
        s.lastDiscountBp = cfg.startDiscountBp;
        s.lastUpdatedBucket = 0;
        s.cfg = cfg;

        // Request current bucket and a couple ahead to warm the pipeline
        uint256 b = _currentBucket(poolId);
        _ensureHandle(poolId, b);
        if (b + 1 < bucketCount(poolId)) _ensureHandle(poolId, b + 1);
        if (b + 2 < bucketCount(poolId)) _ensureHandle(poolId, b + 2);

        emit AuctionStarted(poolId, s.startTime);
    }

    function endAuction(bytes32 poolId) external onlyOwner {
        auctions[poolId].active = false;
        emit AuctionEnded(poolId, uint64(block.timestamp));
    }

    function getCurrentDiscountBp(bytes32 poolId) external view returns (int256) {
        AuctionState storage s = auctions[poolId];
        if (!s.active) return 0;
        return s.lastDiscountBp;
    }

    function bucketCount(bytes32 poolId) public view returns (uint256) {
        AuctionState storage s = auctions[poolId];
        if (s.cfg.bucketSeconds == 0) return 0;
        return (s.cfg.durationSec + s.cfg.bucketSeconds - 1) / s.cfg.bucketSeconds;
    }

    /// @notice Finalize (decrypt and apply) the current bucket if ready; primes next handles; pays optional tip.
    function finalizeCurrentBucket(bytes32 poolId) public {
        AuctionState storage s = auctions[poolId];
        require(s.active, "inactive");
        uint256 b = _currentBucket(poolId);
        _ensureHandle(poolId, b);

        bytes32 h = bucketHandle[poolId][b];
        if (h == bytes32(0)) return;
        if (!cofhe.isReady(h)) return;

        int256 d = cofhe.decrypt(h);

        // Enforce monotonicity and reserve cap onchain
        if (d < s.lastDiscountBp) d = s.lastDiscountBp;
        if (d > s.cfg.reserveDiscountBp) d = s.cfg.reserveDiscountBp;

        if (b >= s.lastUpdatedBucket) {
            s.lastDiscountBp = d;
            s.lastUpdatedBucket = uint64(b);
            emit BucketFinalized(poolId, b, d);

            // Prime next buckets
            if (b + 1 < bucketCount(poolId)) _ensureHandle(poolId, b + 1);
            if (b + 2 < bucketCount(poolId)) _ensureHandle(poolId, b + 2);

            // Optional tip to caller (best-effort)
            if (keeperTipWei > 0 && address(this).balance >= keeperTipWei) {
                (bool ok, ) = msg.sender.call{value: keeperTipWei}("");
                ok;
            }
        }
    }

    /// @notice Convenience function: attempt finalize and return current discount.
    function updateAndGet(bytes32 poolId) external returns (int256) {
        finalizeCurrentBucket(poolId);
        return auctions[poolId].lastDiscountBp;
    }

    function _currentBucket(bytes32 poolId) internal view returns (uint256) {
        AuctionState storage s = auctions[poolId];
        uint256 t = block.timestamp - s.startTime;
        uint256 b = t / s.cfg.bucketSeconds;
        uint256 total = bucketCount(poolId);
        if (total == 0) return 0;
        if (b >= total) b = total - 1;
        return b;
    }

    function _ensureHandle(bytes32 poolId, uint256 b) internal {
        if (bucketHandle[poolId][b] != bytes32(0)) return;
        AuctionState storage s = auctions[poolId];

        bytes32 h = cofhe.requestEval(
            s.enc.eTau,
            s.enc.eEps,
            b,
            abi.encode(
                poolId,
                s.startTime,
                s.cfg.startDiscountBp,
                s.cfg.reserveDiscountBp,
                s.cfg.decayRatePubBpPerSec,
                s.cfg.bucketSeconds,
                s.cfg.durationSec
            )
        );

        bucketHandle[poolId][b] = h;
        emit BucketRequested(poolId, b, h);
    }
}


