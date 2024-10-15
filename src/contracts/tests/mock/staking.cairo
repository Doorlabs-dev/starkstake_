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
    fn stake(
        ref self: TContractState,
        reward_address: ContractAddress,
        operational_address: ContractAddress,
        amount: u128,
        pool_enabled: bool,
        commission: u16,
    );
    fn increase_stake(
        ref self: TContractState, staker_address: ContractAddress, amount: u128
    ) -> u128;
    fn claim_rewards(ref self: TContractState, staker_address: ContractAddress) -> u128;
    fn unstake_intent(ref self: TContractState) -> u64;
    fn unstake_action(ref self: TContractState, staker_address: ContractAddress) -> u128;
    fn staker_info(self: @TContractState, staker_address: ContractAddress) -> StakerInfo;
    fn contract_parameters(self: @TContractState) -> StakingContractInfo;
    fn get_total_stake(self: @TContractState) -> u128;
    fn is_paused(self: @TContractState) -> bool;
    fn set_paused(ref self: TContractState, paused: bool);
    fn set_global_index(ref self: TContractState, index: u64);
    fn set_min_stake(ref self: TContractState, min_stake: u128);

    fn set_pool_contract_class_hash(ref self: TContractState, class_hash: ClassHash) ;
    fn get_deployed_pool(self: @TContractState, staker_address: ContractAddress) -> ContractAddress;
}


#[starknet::contract]
pub mod MockStaking {
    use core::option::OptionTrait;
    use core::num::traits::zero::Zero;
    use starknet::storage::Map;
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_block_timestamp, get_contract_address,
        SyscallResultTrait, syscalls::deploy_syscall, get_tx_info
    };
    use stakestark_::contracts::tests::mock::strk::{ISTRKDispatcher, ISTRKDispatcherTrait};
    use super::{StakerInfo, StakerPoolInfo, StakingContractInfo};

    #[storage]
    struct Storage {
        global_index: u64,
        global_index_last_update_timestamp: u64,
        min_stake: u128,
        staker_info: Map<ContractAddress, Option<StakerInfo>>,
        operational_address_to_staker_address: Map<ContractAddress, ContractAddress>,
        total_stake: u128,
        pool_contract_class_hash: ClassHash,
        reward_supplier: ContractAddress,
        pool_contract_admin: ContractAddress,
        is_paused: bool,
        exit_wait_window: u64,
        deployed_pools: Map<ContractAddress, ContractAddress>,
        strk_token: ISTRKDispatcher,
        strk_token_address: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        NewDelegationPool: NewDelegationPool,
        StakerExitIntent: StakerExitIntent,
        StakerRewardAddressChanged: StakerRewardAddressChanged,
        OperationalAddressChanged: OperationalAddressChanged,
        GlobalIndexUpdated: GlobalIndexUpdated,
        NewStaker: NewStaker,
        StakerRewardClaimed: StakerRewardClaimed,
        DeleteStaker: DeleteStaker,
        RewardsSuppliedToDelegationPool: RewardsSuppliedToDelegationPool,
    }

    #[derive(Drop, starknet::Event)]
    pub struct NewDelegationPool {
        #[key]
        pub staker_address: ContractAddress,
        #[key]
        pub pool_contract: ContractAddress,
        pub commission: u16
    }

    #[derive(Drop, starknet::Event)]
    pub struct StakerExitIntent {
        #[key]
        pub staker_address: ContractAddress,
        pub exit_timestamp: u64,
        pub amount: u128
    }


    #[derive(Drop, starknet::Event)]
    pub struct StakerRewardAddressChanged {
        #[key]
        pub staker_address: ContractAddress,
        pub new_address: ContractAddress,
        pub old_address: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    pub struct OperationalAddressChanged {
        #[key]
        pub staker_address: ContractAddress,
        pub new_address: ContractAddress,
        pub old_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GlobalIndexUpdated {
        pub old_index: u64,
        pub new_index: u64,
        pub global_index_last_update_timestamp: u64,
        pub global_index_current_update_timestamp: u64
    }

    #[derive(Drop, starknet::Event)]
    pub struct NewStaker {
        #[key]
        pub staker_address: ContractAddress,
        pub reward_address: ContractAddress,
        pub operational_address: ContractAddress,
        pub self_stake: u128,
    }

    #[derive(Drop, starknet::Event)]
    pub struct StakerRewardClaimed {
        #[key]
        pub staker_address: ContractAddress,
        pub reward_address: ContractAddress,
        pub amount: u128
    }

    #[derive(Drop, starknet::Event)]
    pub struct DeleteStaker {
        #[key]
        pub staker_address: ContractAddress,
        pub reward_address: ContractAddress,
        pub operational_address: ContractAddress,
        pub pool_contract: Option<ContractAddress>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RewardsSuppliedToDelegationPool {
        #[key]
        pub staker_address: ContractAddress,
        #[key]
        pub pool_address: ContractAddress,
        pub amount: u128
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
        self.global_index_last_update_timestamp.write(get_block_timestamp());
        self.is_paused.write(false);
        self.pool_contract_class_hash.write(pool_contract_class_hash);
        self.strk_token_address.write(strk_address);
        self.strk_token.write(ISTRKDispatcher { contract_address: strk_address });
    }

    #[abi(embed_v0)]
    impl MockStakingImpl of super::IMockStaking<ContractState> {
        fn stake(
            ref self: ContractState,
            reward_address: ContractAddress,
            operational_address: ContractAddress,
            amount: u128,
            pool_enabled: bool,
            commission: u16,
        ) {
            self.assert_not_paused();
            let staker_address = get_caller_address();
            assert(self.staker_info.read(staker_address).is_none(), 'STAKER_EXISTS');
            assert(amount >= self.min_stake.read(), 'AMOUNT_LESS_THAN_MIN_STAKE');

            // Transfer STRK tokens from staker to this contract
            let strk_token = self.strk_token.read();
            strk_token.transfer_from(staker_address, get_contract_address(), amount.into());

            let pool_info = if pool_enabled {
                let pool_contract = self.deploy_pool_contract(staker_address, commission);
                Option::Some(
                    StakerPoolInfo { pool_contract, amount: 0, unclaimed_rewards: 0, commission, }
                )
            } else {
                Option::None
            };

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

            self
                .emit(
                    NewStaker {
                        staker_address, reward_address, operational_address, self_stake: amount
                    }
                );

            if pool_enabled {
                self
                    .emit(
                        NewDelegationPool {
                            staker_address,
                            pool_contract: staker_info.pool_info.unwrap().pool_contract,
                            commission
                        }
                    );
            }
        }

        fn increase_stake(
            ref self: ContractState, staker_address: ContractAddress, amount: u128
        ) -> u128 {
            self.assert_not_paused();
            let mut staker_info = self.get_staker_info(staker_address);
            assert(staker_info.unstake_time.is_none(), 'UNSTAKE_IN_PROGRESS');

            staker_info.amount_own += amount;
            self.staker_info.write(staker_address, Option::Some(staker_info));
            self.total_stake.write(self.total_stake.read() + amount);

            staker_info.amount_own
        }

        fn claim_rewards(ref self: ContractState, staker_address: ContractAddress) -> u128 {
            self.assert_not_paused();
            let mut staker_info = self.get_staker_info(staker_address);
            let amount = staker_info.unclaimed_rewards_own;
            staker_info.unclaimed_rewards_own = 0;
            self.staker_info.write(staker_address, Option::Some(staker_info));

            // Transfer rewards to staker
            let strk_token = self.strk_token.read();
            strk_token.transfer(staker_info.reward_address, amount.into());

            self
                .emit(
                    StakerRewardClaimed {
                        staker_address, reward_address: staker_info.reward_address, amount
                    }
                );
            amount
        }

        fn unstake_intent(ref self: ContractState) -> u64 {
            self.assert_not_paused();
            let staker_address = get_caller_address();
            let mut staker_info = self.get_staker_info(staker_address);
            assert(staker_info.unstake_time.is_none(), 'UNSTAKE_IN_PROGRESS');

            let unstake_time = get_block_timestamp() + self.exit_wait_window.read();
            staker_info.unstake_time = Option::Some(unstake_time);
            self.staker_info.write(staker_address, Option::Some(staker_info));

            let amount = staker_info.amount_own;
            self.total_stake.write(self.total_stake.read() - amount);

            // Transfer STRK tokens back to staker
            let strk_token = self.strk_token.read();
            strk_token.transfer(staker_address, amount.into());

            self.emit(StakerExitIntent { staker_address, exit_timestamp: unstake_time, amount });
            unstake_time
        }

        fn unstake_action(ref self: ContractState, staker_address: ContractAddress) -> u128 {
            self.assert_not_paused();
            let staker_info = self.get_staker_info(staker_address);
            let unstake_time = staker_info.unstake_time.expect('MISSING_UNSTAKE_INTENT');
            assert(get_block_timestamp() >= unstake_time, 'INTENT_WINDOW_NOT_FINISHED');

            let amount = staker_info.amount_own;
            self.staker_info.write(staker_address, Option::None);
            self
                .operational_address_to_staker_address
                .write(staker_info.operational_address, starknet::contract_address_const::<0>());

            self
                .emit(
                    DeleteStaker {
                        staker_address,
                        reward_address: staker_info.reward_address,
                        operational_address: staker_info.operational_address,
                        pool_contract: Option::None,
                    }
                );

            amount
        }

        fn staker_info(self: @ContractState, staker_address: ContractAddress) -> StakerInfo {
            self.get_staker_info(staker_address)
        }

        fn contract_parameters(self: @ContractState) -> StakingContractInfo {
            StakingContractInfo {
                min_stake: self.min_stake.read(),
                token_address: starknet::contract_address_const::<0>(),
                global_index: self.global_index.read(),
                pool_contract_class_hash: self.pool_contract_class_hash.read(),
                reward_supplier: self.reward_supplier.read(),
                exit_wait_window: self.exit_wait_window.read()
            }
        }

        fn get_total_stake(self: @ContractState) -> u128 {
            self.total_stake.read()
        }

        fn is_paused(self: @ContractState) -> bool {
            self.is_paused.read()
        }

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
    
        fn get_deployed_pool(self: @ContractState, staker_address: ContractAddress) -> ContractAddress {
            self.deployed_pools.read(staker_address)
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn assert_not_paused(self: @ContractState) {
            assert(!self.is_paused.read(), 'CONTRACT_IS_PAUSED');
        }

        fn get_staker_info(self: @ContractState, staker_address: ContractAddress) -> StakerInfo {
            self.staker_info.read(staker_address).expect('STAKER_NOT_EXISTS')
        }

        fn deploy_pool_contract(
            ref self: ContractState, staker_address: ContractAddress, commission: u16
        ) -> ContractAddress {
            // 실제 배포 대신 모의 배포 로직

            let mut calldata: Array::<felt252> = array![];
            staker_address.serialize(ref calldata);
            get_contract_address().serialize(ref calldata);
            self.strk_token_address.read().serialize(ref calldata);
            commission.serialize(ref calldata);

            let (deployed_address, _) = starknet::deploy_syscall(
                self.pool_contract_class_hash.read(), 0, calldata.span(), false
            )
                .unwrap_syscall();

            self.deployed_pools.write(staker_address, deployed_address);

            deployed_address
        }
    }

}

