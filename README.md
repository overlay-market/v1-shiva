# Shiva Contract Documentation

## Overview

The `Shiva` contract is designed for interacting with the OverlayV1 protocol. It provides a streamlined way to build, unwind, and manage positions in OverlayV1 markets. It also integrates staking mechanisms through the BerachainRewardsVault, enabling users to stake their collateral to earn rewards.

This contract is:

- **Upgradeable:** Uses the UUPS pattern for contract upgrades.
- **Pausable:** Includes functionality to pause and unpause critical operations.
- **EIP-712 Compliant:** Supports signature-based actions for on-behalf-of operations.

---

## Features

### Core Functionalities

1. **Position Management**
   - **Build Positions:** Allows users to build leveraged positions in OverlayV1 markets.
   - **Unwind Positions:** Enables users to unwind (partially or fully) their positions.
   - **Emergency Withdrawal:** Allows users to withdraw their collateral in case of market shutdown.

2. **Staking and Rewards**
   - Stake collateral to earn rewards through the Berachain Rewards Vault.
   - Unstake collateral when positions are unwound.

3. **On-Behalf-Of Operations**
   - Users can authorize others to build or unwind positions on their behalf using EIP-712 signatures.

4. **Factory and Market Management**
   - Add or remove authorized factories dynamically.
   - Validate markets through authorized factories.

---

## Contract Details

### Key Contracts and Libraries

- **`IOverlayV1Market`:** Interface for OverlayV1 markets.
- **`ShivaStructs`:** Library defining the data structures for `build`, `unwind`, and on-behalf-of operations.
- **`IBerachainRewardsVault`:** Interface for interacting with the Berachain Rewards Vault.

### Key Variables

- **`ovlToken`:** The OverlayV1 Token contract.
- **`ovlState`:** The OverlayV1 State contract.
- **`stakingToken`:** The token used for staking in the rewards vault.
- **`authorizedFactories`:** A list of authorized factories for market validation.
- **`positionOwners`:** Tracks ownership of positions in markets.

### Events

- **`ShivaBuild`:** Emitted when a position is built.
- **`ShivaUnwind`:** Emitted when a position is unwound.
- **`ShivaEmergencyWithdraw`:** Emitted when an emergency withdrawal occurs.
- **`ShivaStake`:** Emitted when tokens are staked.
- **`ShivaUnstake`:** Emitted when tokens are unstaked.
- **`FactoryAdded`:** Emitted when a factory is added.
- **`FactoryRemoved`:** Emitted when a factory is removed.
- **`MarketValidated`:** Emitted when a market is dynamically validated.

---

## Examples

### Build a Position

```solidity
ShivaStructs.Build memory buildParams = ShivaStructs.Build({
    ovlMarket: IOverlayV1Market(0xMarketAddress),
    brokerId: 0,
    isLong: true,
    collateral: 1e18, // 1 OVL
    leverage: 5e18, // 5x leverage
    priceLimit: 0
});
shiva.build(buildParams);
```

### Unwind a Position

```solidity
ShivaStructs.Unwind memory unwindParams = ShivaStructs.Unwind({
    ovlMarket: IOverlayV1Market(0xMarketAddress),
    brokerId: 0,
    positionId: 1,
    fraction: 5e17, // Unwind 50% of the position
    priceLimit: 0
});
shiva.unwind(unwindParams);
```

### Build a Position on Behalf of a User
  
```solidity
ShivaStructs.Build memory buildParams = ShivaStructs.Build({
    ovlMarket: IOverlayV1Market(0xMarketAddress),
    brokerId: 0,
    isLong: true,
    collateral: 1e18,
    leverage: 5e18,
    priceLimit: 0
});
ShivaStructs.OnBehalfOf memory onBehalfOfParams = ShivaStructs.OnBehalfOf({
    owner: 0xUserAddress,
    deadline: uint48(block.timestamp + 1 hours),
    signature: 0xSignatureBytes
});
shiva.build(buildParams, onBehalfOfParams);
```

### Security Features

- **Ownership Checks**: Ensures only position owners can unwind or withdraw positions.
- **Signature Verification**: Uses EIP-712 for secure on-behalf-of operations.
- **Market Validation**: Markets must be authorized through factories or explicitly validated.

### Development Notes

#### Dependencies

- OpenZeppelin contracts for cryptographic utilities and upgradeable functionality.
- OverlayV1 contracts for market interaction.
- Berachain contracts for staking and rewards.