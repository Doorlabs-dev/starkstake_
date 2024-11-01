use starknet::{ContractAddress, ClassHash};

// Mock structures and types
#[derive(Copy, Drop, Serde, starknet::Store)]
    pub struct StakerInfo {
        pub reward_address: ContractAddress,
        pub operational_address: ContractAddress,
        pub unstake_time: Option<u64>,
        pub amount_own: u128,
        pub index: u64,
        pub unclaimed_rewards_own: u128,
        pub pool_info: Option<StakerPoolInfo>,
    }

    #[derive(Copy, Drop, Serde, starknet::Store)]
    pub struct StakerPoolInfo {
        pub pool_contract: ContractAddress,
        pub amount: u128,
        pub unclaimed_rewards: u128,
        pub commission: u16,
    }

#[derive(Copy, Drop, Serde)]
pub struct StakingContractInfo {
    pub min_stake: u128,
    pub token_address: ContractAddress,
    pub global_index: u64,
    pub pool_contract_class_hash: ClassHash,
    pub reward_supplier: ContractAddress,
    pub exit_wait_window: u64
}

#[starknet::interface]
pub trait IMockStaking<TContractState> {
    // Core staking functions
    fn stake(
        ref self: TContractState,
        reward_address: ContractAddress,
        operational_address: ContractAddress,
        amount: u128,
        pool_enabled: bool,
        commission: u16,
    );
    fn increase_stake(ref self: TContractState, staker_address: ContractAddress, amount: u128) -> u128;
    fn claim_rewards(ref self: TContractState, staker_address: ContractAddress) -> u128;
    fn unstake_intent(ref self: TContractState) -> u64;
    fn unstake_action(ref self: TContractState, staker_address: ContractAddress) -> u128;

    // View functions
    fn staker_info(self: @TContractState, staker_address: ContractAddress) -> StakerInfo;
    fn get_total_stake(self: @TContractState) -> u128;
    fn is_paused(self: @TContractState) -> bool;

    // Test helper functions
    fn set_paused(ref self: TContractState, paused: bool);
    fn set_global_index(ref self: TContractState, index: u64);
    fn set_min_stake(ref self: TContractState, min_stake: u128);
    fn set_pool_contract_class_hash(ref self: TContractState, class_hash: ClassHash);
    fn get_deployed_pool(self: @TContractState, staker_address: ContractAddress) -> ContractAddress;
}

#[starknet::contract]
pub mod MockStaking {
    use super::{StakerInfo, StakerPoolInfo};
    use core::option::OptionTrait;
    use core::num::traits::zero::Zero;
    use starknet::storage::Map;
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_block_timestamp, get_contract_address,
        SyscallResultTrait, syscalls::deploy_syscall
    };
    use stakestark_::interfaces::i_starknet_staking::{IPool, IPoolDispatcher, IPoolDispatcherTrait};
    use stakestark_::contracts::tests::mock::strk::{ISTRKDispatcher, ISTRKDispatcherTrait};

    #[storage]
    struct Storage {
        global_index: u64,
        min_stake: u128,
        total_stake: u128,
        is_paused: bool,
        exit_wait_window: u64,
        staker_info: Map<ContractAddress, Option<StakerInfo>>,
        operational_address_to_staker_address: Map<ContractAddress, ContractAddress>,
        pool_contract_class_hash: ClassHash,
        deployed_pools: Map<ContractAddress, ContractAddress>,
        strk_token: ISTRKDispatcher,
        strk_token_address: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        NewStaker: NewStaker,
        StakeBalanceChanged: StakeBalanceChanged,
        StakerExitIntent: StakerExitIntent,
        Unstaked: Unstaked,
        RewardsClaimed: RewardsClaimed,
        DelegationPoolCreated: DelegationPoolCreated,
    }

    #[derive(Drop, starknet::Event)]
    struct NewStaker {
        pub staker_address: ContractAddress,
        pub reward_address: ContractAddress,
        pub operational_address: ContractAddress,
        pub amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct StakeBalanceChanged {
        pub staker_address: ContractAddress,
        pub old_self_stake: u128,
        pub old_delegated_stake: u128,
        pub new_self_stake: u128,
        pub new_delegated_stake: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct StakerExitIntent {
        pub staker_address: ContractAddress,
        pub exit_timestamp: u64,
        pub amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct Unstaked {
        pub staker_address: ContractAddress,
        pub amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct RewardsClaimed {
        pub staker_address: ContractAddress,
        pub amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct DelegationPoolCreated {
        pub staker_address: ContractAddress,
        pub pool_address: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        min_stake: u128,
        exit_wait_window: u64,
        pool_contract_class_hash: ClassHash,
        strk_address: ContractAddress
    ) {
        self.min_stake.write(min_stake);
        self.exit_wait_window.write(exit_wait_window);
        self.global_index.write(0);
        self.is_paused.write(false);
        self.strk_token.write(ISTRKDispatcher { contract_address: strk_address });
        self.strk_token_address.write(strk_address);
        self.pool_contract_class_hash.write(pool_contract_class_hash);
    }

    #[abi(embed_v0)]
    impl MockStaking of super::IMockStaking<ContractState> {
        fn stake(
            ref self: ContractState,
            reward_address: ContractAddress,
            operational_address: ContractAddress,
            amount: u128,
            pool_enabled: bool,
            commission: u16,
        ) {
            assert(!self.is_paused.read(), 'Contract is paused');
            let staker_address = get_caller_address();
            assert(self.staker_info.read(staker_address).is_none(), 'Already staked');
            assert(amount >= self.min_stake.read(), 'Below min stake');

            // Transfer tokens
            let strk_token = self.strk_token.read();
            strk_token.transfer_from(staker_address, get_contract_address(), amount.into());

            // Create pool if needed
            let pool_info = if pool_enabled {
                let pool_contract = self.deploy_pool(staker_address, commission);
                self.emit(DelegationPoolCreated { staker_address, pool_address: pool_contract });
                Option::Some(
                    StakerPoolInfo { pool_contract, amount: 0, unclaimed_rewards: 0, commission }
                )
            } else {
                Option::None
            };

            // Update state
            let staker_info = StakerInfo {
                reward_address,
                operational_address,
                unstake_time: Option::None,
                amount_own: amount,
                index: self.global_index.read(),
                unclaimed_rewards_own: 0,
                pool_info,
            };

            self.staker_info.write(staker_address, Option::Some(staker_info));
            self.operational_address_to_staker_address.write(operational_address, staker_address);
            self.total_stake.write(self.total_stake.read() + amount);

            // Emit events
            self.emit(NewStaker { 
                staker_address, 
                reward_address, 
                operational_address, 
                amount 
            });
            self.emit(StakeBalanceChanged {
                staker_address,
                old_self_stake: 0,
                old_delegated_stake: 0,
                new_self_stake: amount,
                new_delegated_stake: 0,
            });
        }

        fn increase_stake(
            ref self: ContractState, staker_address: ContractAddress, amount: u128
        ) -> u128 {
            assert(!self.is_paused.read(), 'Contract is paused');
            
            let mut staker_info = self.get_staker_info(staker_address);
            assert(staker_info.unstake_time.is_none(), 'Unstake in progress');
            
            // Transfer tokens
            let strk_token = self.strk_token.read();
            strk_token.transfer_from(get_caller_address(), get_contract_address(), amount.into());

            // Update state
            let old_amount = staker_info.amount_own;
            staker_info.amount_own += amount;
            self.staker_info.write(staker_address, Option::Some(staker_info));
            self.total_stake.write(self.total_stake.read() + amount);

            // Emit event
            self.emit(StakeBalanceChanged {
                staker_address,
                old_self_stake: old_amount,
                old_delegated_stake: 0,
                new_self_stake: staker_info.amount_own,
                new_delegated_stake: 0,
            });

            staker_info.amount_own
        }

        fn claim_rewards(ref self: ContractState, staker_address: ContractAddress) -> u128 {
            assert(!self.is_paused.read(), 'Contract is paused');
            
            let mut staker_info = self.get_staker_info(staker_address);
            let caller = get_caller_address();
            assert(
                caller == staker_address || caller == staker_info.reward_address, 
                'Not authorized'
            );

            let amount = staker_info.unclaimed_rewards_own;
            if amount > 0 {
                staker_info.unclaimed_rewards_own = 0;
                self.staker_info.write(staker_address, Option::Some(staker_info));

                // Transfer rewards
                let strk_token = self.strk_token.read();
                strk_token.transfer(staker_info.reward_address, amount.into());

                self.emit(RewardsClaimed { staker_address, amount });
            }

            amount
        }

        fn unstake_intent(ref self: ContractState) -> u64 {
            assert(!self.is_paused.read(), 'Contract is paused');
            
            let staker_address = get_caller_address();
            let mut staker_info = self.get_staker_info(staker_address);
            assert(staker_info.unstake_time.is_none(), 'Unstake in progress');

            // Set unstake time
            let unstake_time = get_block_timestamp() + self.exit_wait_window.read();
            staker_info.unstake_time = Option::Some(unstake_time);
            
            // Update state
            let amount = staker_info.amount_own;
            self.total_stake.write(self.total_stake.read() - amount);
            self.staker_info.write(staker_address, Option::Some(staker_info));

            self.emit(StakerExitIntent { staker_address, exit_timestamp: unstake_time, amount });
            unstake_time
        }

        fn unstake_action(ref self: ContractState, staker_address: ContractAddress) -> u128 {
            assert(!self.is_paused.read(), 'Contract is paused');
            
            let staker_info = self.get_staker_info(staker_address);
            let unstake_time = staker_info.unstake_time.expect('No unstake intent');
            assert(get_block_timestamp() >= unstake_time, 'Still locked');

            let amount = staker_info.amount_own;
            
            // Transfer tokens back
            let strk_token = self.strk_token.read();
            strk_token.transfer(staker_address, amount.into());

            // Clear staker info
            self.staker_info.write(staker_address, Option::None);
            self.operational_address_to_staker_address.write(
                staker_info.operational_address, 
                starknet::contract_address_const::<0>()
            );

            self.emit(Unstaked { staker_address, amount });
            amount
        }

        // View functions

        fn staker_info(self: @ContractState, staker_address: ContractAddress) -> StakerInfo {
            self.get_staker_info(staker_address)
        }

        fn get_total_stake(self: @ContractState) -> u128 {
            self.total_stake.read()
        }

        fn is_paused(self: @ContractState) -> bool {
            self.is_paused.read()
        }

        // Test helper functions

        fn set_paused(ref self: ContractState, paused: bool) {
            self.is_paused.write(paused);
        }

        fn set_global_index(ref self: ContractState, index: u64) {
            self.global_index.write(index);
        }

        fn set_min_stake(ref self: ContractState, min_stake: u128) {
            self.min_stake.write(min_stake);
        }

        fn set_pool_contract_class_hash(ref self: ContractState, class_hash: ClassHash) {
            self.pool_contract_class_hash.write(class_hash);
        }

        fn get_deployed_pool(
            self: @ContractState, staker_address: ContractAddress
        ) -> ContractAddress {
            self.deployed_pools.read(staker_address)
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn get_staker_info(self: @ContractState, staker_address: ContractAddress) -> StakerInfo {
            self.staker_info.read(staker_address).expect('Staker not found')
        }

        fn deploy_pool(
            ref self: ContractState, staker_address: ContractAddress, commission: u16
        ) -> ContractAddress {
            let mut calldata = array![];
            staker_address.serialize(ref calldata);
            get_contract_address().serialize(ref calldata);
            self.strk_token_address.read().serialize(ref calldata);
            commission.serialize(ref calldata);

            let (deployed_address, _) = deploy_syscall(
                self.pool_contract_class_hash.read(), 0, calldata.span(), false
            ).unwrap_syscall();

            self.deployed_pools.write(staker_address, deployed_address);
            deployed_address
        }
    }
}

