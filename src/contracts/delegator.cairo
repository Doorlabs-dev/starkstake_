#[starknet::contract]
mod Delegator {
    use core::option::OptionTrait;
    use core::traits::TryInto;
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_block_timestamp, get_contract_address,
    };
    use starknet::storage::Map;

    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::security::PausableComponent;
    use openzeppelin::security::ReentrancyGuardComponent;
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    use stake_stark::components::access_control::RoleBasedAccessControlComponent;
    use stake_stark::interfaces::{
        i_delegator::IDelegator, 
        i_delegator::Events,
        i_starknet_staking::IPoolDispatcher,
        i_starknet_staking::IPoolDispatcherTrait
    };

    use stake_stark::utils::constants::{ADMIN_ROLE, LIQUID_STAKING_ROLE};

    // Component declarations
    component!(path: AccessControlComponent, storage: oz_access_control, event: AccessControlEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent
    );
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: RoleBasedAccessControlComponent, storage: access_control, event: RBACEvent);

    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl RoleBasedAccessControlImpl =
        RoleBasedAccessControlComponent::RoleBasedAccessControlImpl<ContractState>;

    impl InternalImpl = RoleBasedAccessControlComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        liquid_staking_protocol: ContractAddress,
        pool_contract: ContractAddress,
        strk_token: ContractAddress,
        total_stake: u256,
        last_reward_claim_time: u64,
        is_in_pool: bool,
        #[substorage(v0)]
        oz_access_control: AccessControlComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        access_control: RoleBasedAccessControlComponent::Storage
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Delegated: Events::Delegated,
        WithdrawalRequested: Events::WithdrawalRequested,
        WithdrawalProcessed: Events::WithdrawalProcessed,
        RewardsClaimed: Events::RewardsClaimed,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        RBACEvent: RoleBasedAccessControlComponent::Event,
    }


    /// Initializes the Delegator contract
    /// @param liquid_staking_protocol: Address of the liquid staking protocol
    /// @param pool_contract: Address of the Starknet staking pool contract
    /// @param strk_token: Address of the STRK token
    #[constructor]
    fn constructor(
        ref self: ContractState,
        liquid_staking_protocol: ContractAddress,
        pool_contract: ContractAddress,
        strk_token: ContractAddress,
    ) {
        self.liquid_staking_protocol.write(liquid_staking_protocol);
        self.pool_contract.write(pool_contract);
        self.strk_token.write(strk_token);
        self.total_stake.write(0);
        self.last_reward_claim_time.write(get_block_timestamp());

        self.access_control.grant_role(ADMIN_ROLE, liquid_staking_protocol);
        self.access_control.grant_role(LIQUID_STAKING_ROLE, liquid_staking_protocol);
    }

    #[abi(embed_v0)]
    impl Delegator of IDelegator<ContractState> {
        /// Delegates tokens to the Starknet staking pool
        /// @param amount: Amount of tokens to delegate
        fn delegate(ref self: ContractState, amount: u256) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();
            self.access_control.assert_only_role(LIQUID_STAKING_ROLE);

            let strk_token = IERC20Dispatcher { contract_address: self.strk_token.read() };

            strk_token.approve(self.pool_contract.read(), amount);

            let pool = IPoolDispatcher { contract_address: self.pool_contract.read() };
            let amount_u128: u128 = amount.try_into().unwrap();
            
            if !self.is_in_pool.read() {
                // First time entering the pool
                let success = pool.enter_delegation_pool(self.liquid_staking_protocol.read(), amount_u128);
                assert(success, 'Failed to enter delegation pool');
                self.is_in_pool.write(true);
            } else {
                // Already in the pool, so add to existing delegation
                let new_total = pool.add_to_delegation_pool(get_contract_address(), amount_u128);
                assert(new_total > 0, 'Failed to add delegation pool');
            }

            self.total_stake.write(self.total_stake.read() + amount);

            self.emit(Events::Delegated { amount });
            self.reentrancy_guard.end();
        }

        /// Requests a withdrawal from the Starknet staking pool
        /// @param amount: Amount of tokens to withdraw
        /// @return u64: Timestamp when withdrawal will be possible
        fn request_withdrawal(ref self: ContractState, amount: u256) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();
            self.access_control.assert_only_role(LIQUID_STAKING_ROLE);

            let pool = IPoolDispatcher { contract_address: self.pool_contract.read() };
            pool.exit_delegation_pool_intent(amount.try_into().unwrap());

            self.total_stake.write(self.total_stake.read() - amount);

            self.emit(Events::WithdrawalRequested { amount });

            self.reentrancy_guard.end();
        }

        /// Processes a withdrawal from the Starknet staking pool
        /// @return u256: Amount of tokens withdrawn
        fn process_withdrawal(ref self: ContractState) -> u256 {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();
            self.access_control.assert_only_role(LIQUID_STAKING_ROLE);

            let pool = IPoolDispatcher { contract_address: self.pool_contract.read() };

            let withdrawn_amount: u256 = pool
                .exit_delegation_pool_action(get_contract_address())
                .into();

            let strk_token = IERC20Dispatcher { contract_address: self.strk_token.read() };
            strk_token.transfer(self.liquid_staking_protocol.read(), withdrawn_amount);

            self.emit(Events::WithdrawalProcessed { amount: withdrawn_amount });

            self.reentrancy_guard.end();
            withdrawn_amount
        }

        /// Collects rewards from the Starknet staking pool
        /// @return u256: Amount of rewards collected
        fn collect_rewards(ref self: ContractState) -> u256 {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();
            self.access_control.assert_only_role(LIQUID_STAKING_ROLE);

            let pool = IPoolDispatcher { contract_address: self.pool_contract.read() };
            let rewards: u256 = pool.claim_rewards(get_contract_address()).into();

            let strk_token = IERC20Dispatcher { contract_address: self.strk_token.read() };
            strk_token.transfer(self.liquid_staking_protocol.read(), rewards);

            self.last_reward_claim_time.write(get_block_timestamp());

            self.emit(Events::RewardsClaimed { amount: rewards });

            self.reentrancy_guard.end();
            rewards
        }

        /// Upgrades the contract to a new implementation
        /// @param new_class_hash: The class hash of the new implementation
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            self.upgradeable.upgrade(new_class_hash);
        }

        /// Gets the total stake of this delegator
        /// @return u256: Total stake amount
        fn get_total_stake(self: @ContractState) -> u256 {
            self.total_stake.read()
        }

        /// Gets the last time rewards were claimed
        /// @return u64: Timestamp of last reward claim
        fn get_last_reward_claim_time(self: @ContractState) -> u64 {
            self.last_reward_claim_time.read()
        }
    }

}
