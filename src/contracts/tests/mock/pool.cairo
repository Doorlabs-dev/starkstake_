use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct PoolMemberInfo {
    pub reward_address: ContractAddress,
    pub amount: u128,
    pub index: u64,
    pub unclaimed_rewards: u128,
    pub commission: u16,
    pub unpool_time: Option<u64>,
    pub unpool_amount: u128,
}

#[derive(Copy, Drop, Serde)]
pub struct PoolContractInfo {
    pub staker_address: ContractAddress,
    pub final_staker_index: Option<u64>,
    pub staking_contract: ContractAddress,
    pub token_address: ContractAddress,
    pub commission: u16,
}

#[starknet::interface]
pub trait IMockPool<TContractState> {
    // Core delegation functions
    fn enter_delegation_pool(
        ref self: TContractState,
        reward_address: ContractAddress,
        amount: u128
    ) -> ContractAddress;
    
    fn add_to_delegation_pool(
        ref self: TContractState,
        pool_member: ContractAddress,
        amount: u128
    ) -> u128;
    
    fn exit_delegation_pool_intent(ref self: TContractState, amount: u128);
    
    fn exit_delegation_pool_action(
        ref self: TContractState,
        pool_member: ContractAddress
    ) -> u128;
    
    fn claim_rewards(ref self: TContractState, pool_member: ContractAddress) -> u128;

    // Switch pool functions
    fn switch_delegation_pool(
        ref self: TContractState,
        to_staker: ContractAddress,
        to_pool: ContractAddress,
        amount: u128
    ) -> u128;

    // View functions    
    fn pool_member_info(self: @TContractState, pool_member: ContractAddress) -> PoolMemberInfo;
    fn contract_parameters(self: @TContractState) -> PoolContractInfo;
    fn set_final_staker_index(ref self: TContractState, final_staker_index: u64);
}

#[starknet::contract]
pub mod MockPool {
    use core::option::OptionTrait;
    //use core::num::traits::zero::Zero;
    use starknet::storage::Map;
    use starknet::{
        ContractAddress, get_caller_address, get_block_timestamp, get_contract_address
    };
    use starkstake_::contracts::tests::mock::strk::{ISTRKDispatcher, ISTRKDispatcherTrait};
    use super::{PoolMemberInfo, PoolContractInfo};

    #[storage]
    struct Storage {
        staker_address: ContractAddress,
        pool_member_info: Map<ContractAddress, Option<PoolMemberInfo>>,
        final_staker_index: Option<u64>,
        staking_contract: ContractAddress,
        token_address: ContractAddress,
        commission: u16,
        total_pool_amount: u128,
        strk_token: ISTRKDispatcher,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        PoolMemberExitIntent: PoolMemberExitIntent,
        DelegationPoolMemberBalanceChanged: DelegationPoolMemberBalanceChanged,
        PoolMemberRewardAddressChanged: PoolMemberRewardAddressChanged,
        FinalIndexSet: FinalIndexSet,
        PoolMemberRewardClaimed: PoolMemberRewardClaimed,
        DeletePoolMember: DeletePoolMember,
        NewPoolMember: NewPoolMember,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolMemberExitIntent {
        pub pool_member: ContractAddress,
        pub exit_timestamp: u64,
        pub amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    pub struct DelegationPoolMemberBalanceChanged {
        pub pool_member: ContractAddress,
        pub old_delegated_stake: u128,
        pub new_delegated_stake: u128,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolMemberRewardAddressChanged {
        pub pool_member: ContractAddress,
        pub old_reward_address: ContractAddress,
        pub new_reward_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FinalIndexSet {
        pub staker_address: ContractAddress,
        pub final_staker_index: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PoolMemberRewardClaimed {
        pub pool_member: ContractAddress,
        pub reward_address: ContractAddress,
        pub amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    pub struct DeletePoolMember {
        pub pool_member: ContractAddress,
        pub reward_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct NewPoolMember {
        pub pool_member: ContractAddress,
        pub staker_address: ContractAddress,
        pub reward_address: ContractAddress,
        pub amount: u128,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        staker_address: ContractAddress,
        staking_contract: ContractAddress,
        token_address: ContractAddress,
        commission: u16
    ) {
        self.staker_address.write(staker_address);
        self.staking_contract.write(staking_contract);
        self.token_address.write(token_address);
        self.strk_token.write(ISTRKDispatcher { contract_address: token_address });
        self.commission.write(commission);
        self.total_pool_amount.write(0);
    }

    #[abi(embed_v0)]
    impl MockPoolImpl of super::IMockPool<ContractState> {
        fn enter_delegation_pool(
            ref self: ContractState,
            reward_address: ContractAddress,
            amount: u128
        ) -> ContractAddress {
            let pool_member = get_caller_address();
            assert(self.pool_member_info.read(pool_member).is_none(), 'POOL_MEMBER_EXISTS');
            assert(amount > 0, 'AMOUNT_IS_ZERO');

            // Transfer tokens
            let strk_token = self.strk_token.read();
            strk_token.transfer_from(pool_member, get_contract_address(), amount.into());

            // Initialize pool member
            self.pool_member_info.write(
                pool_member,
                Option::Some(
                    PoolMemberInfo {
                        reward_address,
                        amount,
                        index: 0,
                        unclaimed_rewards: 0,
                        commission: self.commission.read(),
                        unpool_time: Option::None,
                        unpool_amount: 0,
                    }
                )
            );
            self.total_pool_amount.write(self.total_pool_amount.read() + amount);

            self.emit(NewPoolMember {
                pool_member,
                staker_address: self.staker_address.read(),
                reward_address,
                amount
            });

            get_contract_address()
        }

        fn add_to_delegation_pool(
            ref self: ContractState,
            pool_member: ContractAddress,
            amount: u128
        ) -> u128 {
            let mut pool_member_info = self.get_pool_member_info(pool_member);
            let old_amount = pool_member_info.amount;

            // Transfer tokens
            let strk_token = self.strk_token.read();
            strk_token.transfer_from(get_caller_address(), get_contract_address(), amount.into());

            pool_member_info.amount += amount;
            self.pool_member_info.write(pool_member, Option::Some(pool_member_info));
            self.total_pool_amount.write(self.total_pool_amount.read() + amount);

            self.emit(DelegationPoolMemberBalanceChanged {
                pool_member,
                old_delegated_stake: old_amount,
                new_delegated_stake: pool_member_info.amount
            });

            pool_member_info.amount
        }

        fn exit_delegation_pool_intent(ref self: ContractState, amount: u128) {
            let pool_member = get_caller_address();
            let mut pool_member_info = self.get_pool_member_info(pool_member);
            assert(amount <= pool_member_info.amount + pool_member_info.unpool_amount, 'AMOUNT_TOO_HIGH');

            let unpool_time = get_block_timestamp() + 86400; // 1 day delay
            if amount.is_zero() {
                pool_member_info.unpool_time = Option::None;
            } else {
                pool_member_info.unpool_time = Option::Some(unpool_time);
            }
            
            pool_member_info.unpool_amount = amount;
            pool_member_info.amount = pool_member_info.amount + pool_member_info.unpool_amount - amount;
            self.pool_member_info.write(pool_member, Option::Some(pool_member_info));

            self.emit(PoolMemberExitIntent {
                pool_member,
                exit_timestamp: unpool_time,
                amount
            });
        }

        fn exit_delegation_pool_action(
            ref self: ContractState,
            pool_member: ContractAddress
        ) -> u128 {
            let mut pool_member_info = self.get_pool_member_info(pool_member);
            let unpool_time = pool_member_info.unpool_time.expect('MISSING_UNDELEGATE_INTENT');
            assert(get_block_timestamp() >= unpool_time, 'INTENT_WINDOW_NOT_FINISHED');

            let amount = pool_member_info.unpool_amount;
            pool_member_info.unpool_amount = 0;
            pool_member_info.unpool_time = Option::None;

            // Transfer tokens back
            let strk_token = self.strk_token.read();
            strk_token.transfer(pool_member, amount.into());

            if pool_member_info.amount.is_zero() {
                self.pool_member_info.write(pool_member, Option::None);
                self.emit(DeletePoolMember {
                    pool_member,
                    reward_address: pool_member_info.reward_address
                });
            } else {
                self.pool_member_info.write(pool_member, Option::Some(pool_member_info));
            }

            self.total_pool_amount.write(self.total_pool_amount.read() - amount);
            amount
        }

        fn claim_rewards(ref self: ContractState, pool_member: ContractAddress) -> u128 {
            let mut pool_member_info = self.get_pool_member_info(pool_member);
            let caller = get_caller_address();
            assert(
                caller == pool_member || caller == pool_member_info.reward_address,
                'UNAUTHORIZED'
            );
            
            let rewards = pool_member_info.unclaimed_rewards;
            pool_member_info.unclaimed_rewards = 0;
            self.pool_member_info.write(pool_member, Option::Some(pool_member_info));

            // set rewards as 10 STRK for testing
            //let rewards: u128 = 10_000_000_000_000_000_000;
            if rewards > 0 {
                let strk_token = self.strk_token.read();
                strk_token.transfer(pool_member_info.reward_address, rewards.into());

                self.emit(PoolMemberRewardClaimed {
                    pool_member,
                    reward_address: pool_member_info.reward_address,
                    amount: rewards
                });
            }

            rewards
        }

        // New functions for pool switching
        fn switch_delegation_pool(
            ref self: ContractState,
            to_staker: ContractAddress,
            to_pool: ContractAddress,
            amount: u128
        ) -> u128 {
            let pool_member = get_caller_address();
            let mut pool_member_info = self.get_pool_member_info(pool_member);
            
            assert(pool_member_info.unpool_time.is_some(), 'NO_UNDELEGATE_INTENT');
            assert(pool_member_info.unpool_amount >= amount, 'AMOUNT_TOO_HIGH');

            pool_member_info.unpool_amount -= amount;
            if pool_member_info.unpool_amount.is_zero() && pool_member_info.amount.is_zero() {
                self.pool_member_info.write(pool_member, Option::None);
            } else {
                if pool_member_info.unpool_amount.is_zero() {
                    pool_member_info.unpool_time = Option::None;
                }
                self.pool_member_info.write(pool_member, Option::Some(pool_member_info));
            }

            amount
        }

        // View functions remain unchanged
        fn pool_member_info(self: @ContractState, pool_member: ContractAddress) -> PoolMemberInfo {
            self.get_pool_member_info(pool_member)
        }

        fn contract_parameters(self: @ContractState) -> PoolContractInfo {
            PoolContractInfo {
                staker_address: self.staker_address.read(),
                final_staker_index: self.final_staker_index.read(),
                staking_contract: self.staking_contract.read(),
                token_address: self.token_address.read(),
                commission: self.commission.read(),
            }
        }

        fn set_final_staker_index(ref self: ContractState, final_staker_index: u64) {
            assert(
                self.final_staker_index.read().is_none(), 
                'FINAL_STAKER_INDEX_ALREADY_SET'
            );
            self.final_staker_index.write(Option::Some(final_staker_index));
            self.emit(FinalIndexSet {
                staker_address: self.staker_address.read(),
                final_staker_index
            });
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn get_pool_member_info(
            self: @ContractState,
            pool_member: ContractAddress
        ) -> PoolMemberInfo {
            self.pool_member_info.read(pool_member).expect('POOL_MEMBER_DOES_NOT_EXIST')
        }
    }
}