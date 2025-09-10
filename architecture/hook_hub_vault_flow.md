# ShadowBrain Hook ↔ Hub ↔ Vault: Interaction & P/L Settlement

This document explains how the current `ShadowBrainHook`, `ShadowBrainHub`, and `ShadowBrainVault` interact during swaps, how profits/bonuses and penalties are settled, and which functions participate in the flow.

## Components

-   **Hook (`ShadowBrainHook`)**: Applies time-varying penalties/bonuses to swaps and triggers the hub when the auction becomes profitable.
-   **Hub (`ShadowBrainHub`)**: Holds and executes registered automated calls (yield/rebalance/etc.). Only callable by the hook.
-   **Vault (`ShadowBrainVault`)**: Holds funds. Receives penalties and yields; pays bonuses back to traders via PoolManager settlements.

## High-level Flow

1. Auction cycle management (Hook)

-   On interval, the hook starts a new auction for a pool: `active = true`, `startTime = now`, saves `defaultConfig`.
-   The hook computes the current discount using a public linear decay schedule.

2. Swap pricing (Hook)

-   In `beforeSwap`, the hook reads the current discount and:
    -   If negative → apply penalty path (take extra input to vault).
    -   If positive → apply bonus path (add extra output from vault).

3. Settlement mechanics (Hook ↔ Vault ↔ PoolManager)

-   Penalty: the hook causes the PoolManager to transfer additional input tokens to the vault, then records the amount in the vault via `storePenalty`.
-   Bonus: the hook checks the vault’s available balance; if sufficient, it instructs settlement from the vault to the PoolManager, then calls `consumeBonus` to decrement reserves.

4. Profitable trigger (Hook → Hub)

-   In `afterSwap`, if the discount is positive, the hook ends the auction and best-effort calls `hub.executeCalls()`.
-   The hub iterates registered calls and executes enabled ones; any funds or profits generated can later be deposited to the vault via `depositYield`.

---

## Detailed Function Flow

### Hook: Core

-   `getHookPermissions()`

    -   Declares `beforeSwap` and `afterSwap` permissions and `beforeSwapReturnDelta` usage for amount adjustments.

-   `_beforeSwap(sender, key, params, hookData)`

    -   Starts auction if interval elapsed and inactive.
    -   Computes current discount using `getCurrentDiscount`.
    -   Calls `_applyAuctionPricing(...)` which routes to penalty/bonus handlers or no-op.

-   `_afterSwap(_, key, params, _, _)`

    -   If auction active and discount > 0: end auction; try `hub.executeCalls()` inside `try/catch` (non-reverting).

-   `getCurrentDiscount(poolId)`

    -   Public linear schedule: `current = start + decayRate * timeElapsed`, capped by `reserveDiscount`.

-   `_startAuction(poolId)` / `_endAuction(poolId)`

    -   Toggle `active`, set/reset `startTime`, update `lastExecution` time.

-   `getSwapQuote(key, amountIn, zeroForOne)`

    -   View helper: shows current penalty/bonus outcome under the simplified pricing (1:1 base), and when breakeven may occur.

-   `updateDefaultConfig(newConfig)` / `setHub(hubAddress)`
    -   Ops/admin: update auction config; set hub reference.

### Hook: Penalty Path (negative discount)

-   `_applyPenalty(key, amountSpecified, currentDiscount, sender, params)`
    -   Computes `penaltyAmount = amountSpecified * (-discount) / 10000`.
    -   Determines the swap’s specified currency (the input side for this direction).
    -   Uses `CurrencySettler` to make the PoolManager transfer `penaltyAmount` of the specified token to the `vault`.
    -   Calls `vault.storePenalty(token, penaltyAmount)` to increase vault reserves.
    -   Returns a `BeforeSwapDelta` reporting a positive specified delta (hook took from user via manager), which the PoolManager expects the trader to settle.

### Hook: Bonus Path (positive discount)

-   `_applyBonus(key, amountSpecified, currentDiscount, sender, params)`
    -   Computes `bonusAmount = amountSpecified * discount / 10000`.
    -   Determines the unspecified currency (the output side for this direction).
    -   Checks `vault.getAvailableBalance(outputToken) >= bonusAmount`.
    -   If sufficient:
        -   Calls `unspecified.settle(poolManager, address(vault), bonusAmount, false)` so PoolManager can pay extra output to the trader.
        -   Calls `vault.consumeBonus(outputToken, bonusAmount)` to decrement vault reserves.
        -   Returns a `BeforeSwapDelta` with a negative unspecified delta (hook paid manager) reflecting the bonus settlement.
    -   If insufficient: returns zero delta (no bonus granted).

### Vault

-   `depositYield(token, amount)`

    -   Pulls `amount` tokens from caller into the vault and increases `tokenReserves[token]`.

-   `payBonus(token, amount, recipient)`

    -   Direct send path for out-of-hook usage (hook-only function). Not used in the current pool-manager settlement path, but available.

-   `storePenalty(token, amount)` (onlyHook)

    -   Increases `tokenReserves[token]` when a penalty is collected.

-   `consumeBonus(token, amount)` (onlyHook)

    -   Decreases `tokenReserves[token]` when a bonus was granted via settlement.

-   `getAvailableBalance(token)` (view)

    -   Returns reserve amount available for bonuses.

-   Owner ops: `addFunds`, `emergencyWithdraw`, `approveSpender`.

Notes:

-   `onlyHook` guards prevent arbitrary accounts from mutating balances tied to swap flows.
-   The hook must be deployed first so the vault constructor can set `hook = msg.sender`.

### Hub

-   `setShadowBrainHook(hook)` (onlyOwner)

    -   Registers which hook contract can trigger automated executions.

-   `registerCall(target, callData, value)` (onlyOwner)

    -   Appends an enabled call to the internal list; returns its id.

-   `updateCall(id, enabled)` (onlyOwner)

    -   Toggles a call’s enabled flag.

-   `getCall(id)` / `callsCount()` (view)

    -   Read helpers for offchain/ops tooling.

-   `executeCalls()` (onlyHook)
    -   Iterates all calls; for each enabled call: `target.call{value}(callData)`.
    -   Reverts if a call fails (MVP behavior). Consider best-effort try/catch variants if needed.
    -   Increments `totalCallsExecuted` and emits `CallExecuted`.

---

## Event Trace (Typical Positive-Side Flow)

1. User swaps during late auction phase (discount > 0):

-   Hook `_beforeSwap` computes positive discount and enters bonus path.
-   Emits `SwapWithBonus(poolId, user, bonusAmount)`.
-   Vault balance for output token decreases by `bonusAmount`.

2. Hook `_afterSwap` sees discount > 0:

-   Ends auction and calls `hub.executeCalls()` (best-effort; non-reverting in hook via try/catch).
-   Hub emits `CallExecuted(...)` for each call.

3. Later, yields are deposited:

-   An external actor calls `vault.depositYield(token, amount)` to add realized profits to reserves.
-   Vault emits `YieldDeposited(token, amount)`.

## Security & Invariants

-   Monotonic/cap: public linear formula ensures discount never exceeds `reserveDiscount`.
-   Vault mutators (`storePenalty`, `consumeBonus`, `payBonus`) are `onlyHook`.
-   Hub executions are restricted to the registered hook (`onlyHook`).
-   Bonus path requires vault sufficiency; otherwise no bonus is paid.
-   Hook wraps hub call with `try/catch` to avoid swap reverts if executions fail.

---

## File References

-   Hook: `unibrain/src/ShadowBrainHook.sol`
-   Hub: `unibrain/src/ShadowBrainHub.sol`
-   Vault: `unibrain/src/ShadowBrainVault.sol`
