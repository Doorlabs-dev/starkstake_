
# starkstake_

starkstake_ is a liquid staking protocol built on Starknet. It enables users to stake STRK tokens and receive liquid staking tokens (stSTRK) in return. These tokens can be traded, used in DeFi, or redeemed for the underlying STRK tokens after a withdrawal request.

## Project Structure

```
.
├── Scarb.lock
├── Scarb.toml
├── package-lock.json
├── package.json
├── scripts
│   └── deploy.js             # Deployment scripts
└── src
    ├── components
    │   └── access_control.cairo # Role-based access control component
    ├── contracts
    │   ├── delegator.cairo    # Delegator contract for managing validator delegation
    │   ├── stSTRK.cairo       # Liquid staking token (stSTRK) contract
    │   ├── stark_stake.cairo  # Main liquid staking protocol contract
    │   └── tests
    │       ├── mock
    │       │   ├── pool.cairo # Mock pool contract for testing
    │       │   ├── staking.cairo
    │       │   └── strk.cairo
    │       ├── stark_stake_test.cairo # Unit tests for stark_stake contract
    │       └── unit_test.cairo
    ├── interfaces
    │   ├── i_delegator.cairo   # Interface for the Delegator contract
    │   ├── i_stSTRK.cairo      # Interface for stSTRK contract
    │   ├── i_stark_stake.cairo # Interface for the StarkStake contract
    │   └── i_starknet_staking.cairo # Interface for Starknet staking pool
    ├── lib.cairo
    └── utils
        └── constants.cairo     # Common constants used across contracts
```

## Core Contracts

- **StarkStake**: The main contract managing the liquid staking process. Users can deposit STRK tokens and request withdrawals.
- **stSTRK**: The liquid staking token representing a user's share in the protocol. It rebases based on the rewards distributed.
- **Delegator**: Manages the delegation of tokens to the Starknet staking pool and handles rewards collection and withdrawal requests.

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/Doorlabs-dev/starkstake_
   ```

2. Install dependencies:
   ```bash
   npm install
   ```

3. Compile the Cairo contracts:
   ```bash
   scarb build
   ```

## Deployment

To deploy the contracts, run the deployment script:

```bash
node scripts/deploy.js
```

Make sure to configure the script with the appropriate contract addresses and deployment parameters.

## Testing

Run the unit tests using Scarb:

```bash
scarb test
```

## License

This project is licensed under the MIT License.
