# starkstake_ 🪙

Welcome to **starkstake_**, a cutting-edge liquid staking protocol built on Starknet. This repository contains the core contracts and deployment scripts to facilitate decentralized and efficient staking, liquid staking token issuance, and delegator management.

---

## Features ✨

- **Liquid Staking**: Stake your STRK tokens and receive `stSTRK`, a liquid staking token (LST) compliant with ERC-20 standards.
- **Delegator Management**: Interact with Starknet's staking pool through 22 dynamically managed delegator contracts.
- **Modular Architecture**: Built with extensibility and security in mind using OpenZeppelin components.
- **Reward Distribution**: Automated reward distribution with customizable fee ratios.
- **Upgradable Contracts**: Upgradeable components ensure long-term flexibility.
- **Robust Security**: Role-based access control, reentrancy protection, and pausable contracts for enhanced stability.

---

## Repository Structure 📂

```plaintext
starkstake_/
├── Scarb.lock
├── Scarb.toml
├── package-lock.json
├── package.json
├── readme.md
├── scripts
│   └── deploy.js
└── src
    ├── components
    │   └── access_control.cairo
    ├── contracts
    │   ├── delegator.cairo
    │   ├── staked_strk_token.cairo
    │   ├── stark_stake.cairo
    │   └── tests
    │       ├── integration_test.cairo
    │       ├── mock
    │       │   ├── pool.cairo
    │       │   ├── staking.cairo
    │       │   └── strk.cairo
    │       ├── stark_stake_test.cairo
    │       └── test_utils.cairo
    ├── interfaces
    │   ├── i_delegator.cairo
    │   ├── i_staked_strk_token.cairo
    │   ├── i_stark_stake.cairo
    │   └── i_starknet_staking.cairo
    ├── lib.cairo
    └── utils
        └── constants.cairo
```

### Key Files and Directories 📁

- `contracts/`: Contains the main contract files (`stark_stake.cairo`, `delegator.cairo`, etc.).
- `scripts/deploy.js`: Deployment script for deploying contracts to the Starknet network.
- `interfaces/`: Interface files to standardize external contract interactions.
- `utils/constants.cairo`: Shared constants used across contracts.
- `tests/`: Unit tests and mocks for validating contract logic.

---

## Installation & Setup 🛠️

1. **Clone the Repository**:

   ```bash
   git clone https://github.com/Doorlabs-dev/starkstake_.git
   cd starkstake_
   ```

2. **Install Dependencies**:

   ```bash
   npm install
   ```

3. **Configure Environment Variables**:
   Create a `.env` file in the root directory and add the following variables:

   ```plaintext
   RPC_URL=https://your-starknet-rpc-url
   ACCOUNT_ADDRESS=your-account-address
   PRIVATE_KEY=your-private-key
   STRK_TOKEN_ADDRESS=strk-token-address
   POOL_CONTRACT_ADDRESS=pool-contract-address
   PLATFORM_FEE_RECIPIENT=your-fee-recipient-address
   ADMIN_ADDRESS=your-admin-address
   OPERATOR_ADDRESS=your-operator-address
   ```

4. **Build Contracts**:
   Use Scarb to compile Cairo contracts:

   ```bash
   scarb build
   ```

---

## Deployment 🚀

1. Run the deployment script:

   ```bash
   node scripts/deploy.js
   ```

2. Check the `.deployed` file for class hashes and deployed contract addresses.

---

## Testing 🧪

Run tests using your preferred testing framework. Below is an example for running Scarb-based tests:

```bash
scarb test
```

---

## Contribution 🤝

We welcome contributions! Please follow these steps:

1. Fork this repository.
2. Create a new branch for your feature/bug fix.
3. Submit a pull request.

---

## License 📜

This project is licensed under the [MIT License](LICENSE).

---

## Security Audit 🔒

The starkstake_ protocol has undergone a thorough security audit by **Nethermind Security** to ensure the reliability and robustness of its smart contracts. The audit validates compliance with industry standards and highlights our commitment to providing a secure staking solution. The full audit report is available upon request.

---

## Contact 📧

For questions or collaboration, feel free to contact us:

- **Email**: [giwook@doorlabs.io](mailto:giwook@doorlabs.io)
- **Twitter**: [@giwook_stark](https://twitter.com/giwook_stark)

---

### Let’s Build the Future of Staking Together 🚀

