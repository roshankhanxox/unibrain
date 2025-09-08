# UniBrain Architecture

> MEV-Resistant DEX using Encrypted Dutch Auctions on Uniswap v4

## Overview

UniBrain is a Uniswap v4 hook that implements encrypted Dutch auctions to create MEV-resistant swaps while generating sustainable yield for users. The system uses Fully Homomorphic Encryption (FHE) via Fhenix to hide auction parameters from MEV bots, creating predictable timing-based arbitrage opportunities.

## Core Components

### 1. ShadowBrainHook (Uniswap v4 Hook)
**Primary Logic Controller**
- Manages 30-minute Dutch auction cycles
- Implements `beforeSwap()` and `afterSwap()` callbacks
- Calculates encrypted discount rates in real-time
- Modifies swap rates based on auction phase

```solidity
Key Functions:
- beforeSwap(): Apply dynamic discount/penalty to swap rates
- afterSwap(): Trigger hub execution when profitable
- _calculateDiscount(): FHE computation of current auction state
```

### 2. ShadowBrainHub (Execution Engine)
**Automated Operations Controller**
- Stores registered automated calls (yield harvesting, rebalancing, etc.)
- Executes batch operations when triggered by profitable swaps
- Generates real yield that funds user bonuses

```solidity
Key Functions:
- executeCalls(): Loop through and execute all registered operations
- addAutomatedCall(): Register new yield-generating operations
```

### 3. ShadowBrainVault (Treasury & Distribution)
**Fund Management System**
- Accumulates yield from hub executions
- Distributes bonuses to profitable swaps
- Manages pool-weighted allocations
- Stores penalties from early auction phases

```solidity
Key Functions:
- depositYield(): Receive profits from hub operations
- subsidizeSwap(): Distribute bonuses to users
- updatePoolWeight(): Adjust allocations based on activity
```

## Dutch Auction Mechanism

### Auction Parameters (FHE Encrypted)
```
startDiscount: -10% (makes swaps unfavorable)
reserveDiscount: +8% (makes swaps favorable)  
decayRate: 0.0003/sec (dynamic, adjusts based on bot activity)
auctionDuration: 30 minutes
```

### Rate Calculation
```
currentDiscount = startDiscount + (decayRate × timeElapsed)

Timeline:
t=0min:    -10% (users wait)
t=15min:   ~0%  (breakeven)  
t=30min:   +8%  (profitable, bots execute)
```

## System Flow

### 1. Auction Initialization
- Timer reaches 30-minute interval
- Hook encrypts auction parameters using FHE
- Sets `auctionActive = true`
- Begins discount decay calculation

### 2. User Interaction Phase
- Users request swap quotes
- Hook calculates current encrypted discount
- If discount < 0: Show unfavorable rate, user typically waits
- If discount > 0: Show favorable rate, user executes

### 3. Profitable Execution Trigger
- Bot or user executes swap when discount becomes positive
- `afterSwap()` detects profitable execution
- Triggers `ShadowBrainHub.executeCalls()`

### 4. Yield Generation
- Hub executes registered calls:
  - `portfolioRebalancer.rebalance()`
  - `yieldOptimizer.harvest()`
  - `liquidationProtector.check()`
- Generated yield deposited to vault
- Auction resets for next 30-minute cycle

## FHE Implementation

### Encrypted State Variables
```solidity
mapping(PoolKey => euint64) private encryptedDecayRate;     // Dynamic
```

### Dynamic Decay Rate Adjustment
The decay rate adjusts based on MEV bot activity:
- High bot activity → Faster decay → Quicker to profitability
- Low bot activity → Slower decay → Longer auction period

This prevents bots from optimizing timing strategies since they can't predict the exact decay parameters.

## Economic Model

### Revenue Sources
1. **Yield Harvesting**: External protocol rewards (Compound, Aave, etc.)
2. **Portfolio Optimization**: Better capital efficiency
3. **MEV Recapture**: Internalized arbitrage opportunities
4. **Fee Optimization**: Batch operation savings

### Fund Distribution
- **Early Auction**: Penalties collected from impatient users
- **Late Auction**: Bonuses distributed from vault reserves
- **Pool Allocation**: Activity-weighted distribution across pools
- **Self-Sustaining**: Yield generation covers bonus payments

## User Benefits

### For Regular Users
- **Better Rates**: Up to 8% bonus vs market rates
- **MEV Protection**: No sandwich attacks during auctions
- **Predictable Timing**: Know exactly when rates improve
- **Yield Sharing**: Benefit from protocol-generated yield

### For Bots/Arbitrageurs  
- **Profitable Opportunities**: Clear timing-based arbitrage
- **Trigger Rewards**: Executing profitable swaps triggers yield generation
- **Reduced Competition**: Encrypted parameters prevent optimization races

## Technical Specifications

### Hook Permissions
```solidity
beforeSwap: true               // Rate modification
afterSwap: true               // Execution triggering  
beforeSwapReturnDelta: true   // Amount adjustments
```

### Performance Considerations
- FHE operations occur in `beforeSwap()` for real-time rates
- Auction state cached to minimize encryption overhead
- Hub execution batched for gas efficiency

### Integration Requirements
- Fhenix FHE library for encryption
- Uniswap v4 hook interface
- External yield protocols (Compound, Aave, etc.)

## Security Model

### FHE Privacy Guarantees
- Auction parameters hidden from MEV bots
- Dynamic decay prevents timing optimization
- On-chain execution remains transparent

### Economic Security
- Vault reserves back all bonus promises
- Pool weights prevent single-pool drain attacks
- Yield generation provides sustainable funding

## Deployment Strategy

### Phase 1: Bootstrap
- Treasury-funded initial bonuses
- Demonstrate value proposition
- Build user base and liquidity

### Phase 2: Self-Sustaining
- Yield generation covers all bonuses
- Network effects drive adoption
- Expand to multiple pools and chains

---

## Next Steps

1. **FHE Validation**: Confirm approach with Fhenix team
2. **Hook Development**: Implement core auction logic
3. **Vault System**: Build fund management contracts
4. **Integration Testing**: Validate with yield protocols
5. **Security Audit**: Review economic and smart contract security
