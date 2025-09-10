# Encrypted Dutch Auction (V1) - Onchain, CoFHE-backed, No External Triggers

> Swap values increase over time (no user bids). MEV resistance comes from encrypted randomness in the schedule, not from hiding public math.

## Goals

-   Fully onchain progression with no external keepers.
-   Pseudo-realtime via CoFHE handles: request now, decrypt later, cache last finalized discount.
-   Encrypted randomness: time-shift `τ` and slope tweak `ε` break predictability.
-   Monotonic and capped: users never get worse than last finalized discount; never exceeds reserve.

## What’s Public vs Encrypted

-   Public: `startDiscount`, `reserveDiscount`, `decayRate_pub`, `duration`, `bucketSeconds`.
-   Encrypted: `τ` (time shift), `ε` (slope perturbation). These remain ciphertexts; never decrypted.

Discount function (evaluated under FHE):

-   `decay_eff = decayRate_pub + ε`
-   `t_eff = max(0, t - τ)`, where `t = block.timestamp - startTime`
-   `D(t) = clamp(reserveDiscount, startDiscount + decay_eff * t_eff)`

Only per-bucket `D_k` is ever decrypted (one at a time), not `τ`/`ε`.

## Bucketed, Onchain Flow

1. Start auction: set `startTime`, reset `lastDiscountBp = startDiscount`, `lastUpdatedBucket = 0`.
2. Request CoFHE evaluations for current bucket and a couple ahead; receive handles immediately.
3. On each swap (in `beforeSwap`), progress auction:
    - Determine current bucket `b`.
    - Ensure a handle exists for `b`.
    - If `isReady(handle[b])`, decrypt and update `lastDiscountBp` with monotonic/cap guards.
    - Prime `b+1` and `b+2` if missing.
    - Use `lastDiscountBp` synchronously to apply penalty/bonus.
4. End auction when `lastDiscountBp > 0` (as today) or when duration reached.

No background jobs: progression occurs only when the hook is called.

## Contract: `EncryptedDutchAuctionV1`

-   Location: `unibrain/utils/EncryptedDutchAuctionV1.sol`
-   Interface to onchain CoFHE system: `IFhenixCoFHE` with `requestEval`, `isReady`, `decrypt`.
-   State per pool (`bytes32 poolId`):
    -   `startTime`, `lastDiscountBp`, `lastUpdatedBucket`
    -   `ConfigPublic`, `EncryptedParams`
    -   `bucketHandle[bucketIndex] -> handle`
-   Core methods:
    -   `setEncryptedParams(poolId, eTau, eEps)`
    -   `startAuction(poolId, cfg)` / `endAuction(poolId)`
    -   `finalizeCurrentBucket(poolId)` (idempotent; safe if not ready)
    -   `updateAndGet(poolId)` (finalize-if-ready + return current)
    -   `getCurrentDiscountBp(poolId)` (view)

Safety:

-   Monotonic clamp: `new >= last`.
-   Reserve cap: `new <= reserve`.
-   Handles include encoded context `(poolId, startTime, params)` so late results don’t corrupt state.

## Integration with `ShadowBrainHook`

### 1) Add storage for coordinator

-   Keep a contract reference to `EncryptedDutchAuctionV1`.
-   Map `PoolId` to `bytes32` pool ids (e.g., `bytes32 poolId32 = bytes32(PoolId.unwrap(key.toId()));`).

### 2) Auction start

-   In `_startAuction(poolId)`:
    -   Prepare `ConfigPublic` using existing `defaultConfig` fields.
    -   Call `auction.setEncryptedParams(poolId32, eTau, eEps)` (ciphertexts prepared by Fhenix tools).
    -   Call `auction.startAuction(poolId32, cfg)`.

### 3) Before swap

-   Replace current linear `getCurrentDiscount` usage with:
    -   `auction.updateAndGet(poolId32)` (non-view) or `auction.finalizeCurrentBucket(poolId32)` then `auction.getCurrentDiscountBp(poolId32)`.
-   Use returned `discountBp` in your existing `_applyPenalty/_applyBonus`.

### 4) After swap

-   Keep current logic to end the auction when discount > 0:
    -   Check `discountBp > 0` using the coordinator’s last value; call internal `_endAuction` and optionally `hub.executeCalls()`.

### 5) Defaults

-   `bucketSeconds`: 10–15
-   Request “ahead” buckets: 2
-   Ensure `ε` small and positive; ensure `τ` within a bounded window (e.g., 0–300s) so reserve is always reached by duration.

### 6) Testing Guidance

-   Unit test monotonicity and reserve cap under arbitrary out-of-order fulfillments.
-   Simulate delayed readiness: calls to `finalizeCurrentBucket` should be safe when `isReady == false`.
-   Validate end condition: auction ends when `lastDiscountBp > 0` or when `duration` elapsed.

## Security Notes

-   Never decrypt `τ` or `ε` onchain.
-   Only decrypt bucket values `D_k` and only when `isReady`.
-   Clamp monotonicity/cap in the coordinator, not just offchain.
-   Bind handles to `(poolId, startTime)` context in `ctx` to prevent replay into new cycles.

## Developer Checklist

-   Deploy CoFHE system contract (or use test stub implementing `IFhenixCoFHE`).
-   Deploy `EncryptedDutchAuctionV1` with CoFHE address.
-   Grant the hook awareness of the coordinator address.
-   On each new pool cycle:
    -   Create fresh encrypted `eTau`, `eEps`.
    -   Start auction with public config.
-   In `beforeSwap`, call `updateAndGet` and use the returned discount.

---

For questions about Fhenix tooling and ciphertext generation, consult the Fhenix CoFHE docs. This design does not require any offchain keepers, relies on small time buckets for pseudo-realtime, and preserves MEV resistance via encrypted randomness.
