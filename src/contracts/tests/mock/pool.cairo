use starknet::ContractAddress;

#[starknet::interface]
pub trait IMockPool<TContractState> {
    fn enter_delegation_pool(
        ref self: TContractState, reward_address: ContractAddress, amount: u128
    ) -> bool;
    fn add_to_delegation_pool(
        ref self: TContractState, pool_member: ContractAddress, amount: u128
    ) -> u128;
    fn exit_delegation_pool_intent(ref self: TContractState, amount: u128);
    fn exit_delegation_pool_action(ref self: TContractState, pool_member: ContractAddress) -> u128;
    fn claim_rewards(ref self: TContractState, pool_member: ContractAddress) -> u128;
    fn pool_member_info(self: @TContractState, pool_member: ContractAddress) -> PoolMemberInfo;
    fn contract_parameters(self: @TContractState) -> PoolContractInfo;
    fn set_final_staker_index(ref self: TContractState, final_staker_index: u64);
    fn total_pool_amount(self: @TContractState) -> u128;
}

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

#[starknet::contract]
pub mod MockPool {
    use core::option::OptionTrait;
    use core::num::traits::zero::Zero;
    use starknet::storage::Map;
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_block_timestamp, get_contract_address,
        SyscallResultTrait, syscalls::deploy_syscall, get_tx_info
    };
    use super::{PoolMemberInfo, PoolContractInfo};
    use stakestark_::contracts::tests::mock::strk::{ISTRKDispatcher, ISTRKDispatcherTrait};

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
            ref self: ContractState, reward_address: ContractAddress, amount: u128
        ) -> bool{
            let pool_member = get_caller_address();
            assert(self.pool_member_info.read(pool_member).is_none(), 'POOL_MEMBER_EXISTS');
            assert(amount > 0, 'AMOUNT_IS_ZERO');

            // Transfer STRK tokens from pool member to this contract
            let strk_token = self.strk_token.read();
            strk_token.transfer_from(get_caller_address(), get_contract_address(), amount.into());

            self
                .pool_member_info
                .write(
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

            self
                .emit(
                    NewPoolMember {
                        pool_member,
                        staker_address: self.staker_address.read(),
                        reward_address,
                        amount
                    }
                );

            true
        }

        fn add_to_delegation_pool(
            ref self: ContractState, pool_member: ContractAddress, amount: u128
        ) -> u128 {
            let mut pool_member_info = self.get_pool_member_info(pool_member);
            pool_member_info.amount += amount;
            self.pool_member_info.write(pool_member, Option::Some(pool_member_info));
            self.total_pool_amount.write(self.total_pool_amount.read() + amount);

            // Transfer STRK tokens from pool member to this contract
            let strk_token = self.strk_token.read();
            strk_token.transfer_from(get_caller_address(), get_contract_address(), amount.into());

            self
                .emit(
                    DelegationPoolMemberBalanceChanged {
                        pool_member,
                        old_delegated_stake: pool_member_info.amount - amount,
                        new_delegated_stake: pool_member_info.amount
                    }
                );

            pool_member_info.amount
        }

        fn exit_delegation_pool_intent(ref self: ContractState, amount: u128) {
            let pool_member = get_caller_address();
            let mut pool_member_info = self.get_pool_member_info(pool_member);
            assert(amount <= pool_member_info.amount, 'AMOUNT_TOO_HIGH');

            let unpool_time = get_block_timestamp() + 86400; // 1 day delay
            pool_member_info.unpool_time = Option::Some(unpool_time);
            pool_member_info.unpool_amount = amount;
            pool_member_info.amount -= amount;
            self.pool_member_info.write(pool_member, Option::Some(pool_member_info));

            self.emit(PoolMemberExitIntent { pool_member, exit_timestamp: unpool_time, amount });
        }

        fn exit_delegation_pool_action(
            ref self: ContractState, pool_member: ContractAddress
        ) -> u128 {
            let mut pool_member_info = self.get_pool_member_info(pool_member);
            let unpool_time = pool_member_info.unpool_time.expect('MISSING_UNDELEGATE_INTENT');
            assert(get_block_timestamp() >= unpool_time, 'INTENT_WINDOW_NOT_FINISHED');

            let amount = pool_member_info.unpool_amount;
            pool_member_info.unpool_amount = 0;
            pool_member_info.unpool_time = Option::None;

            // Transfer STRK tokens back to pool member
            let strk_token = self.strk_token.read();
            strk_token.transfer(pool_member, amount.into());

            if pool_member_info.amount == 0 {
                self.pool_member_info.write(pool_member, Option::None);
                self
                    .emit(
                        DeletePoolMember {
                            pool_member, reward_address: pool_member_info.reward_address
                        }
                    );
            } else {
                self.pool_member_info.write(pool_member, Option::Some(pool_member_info));
            }

            self.total_pool_amount.write(self.total_pool_amount.read() - amount);
            amount
        }

        fn claim_rewards(ref self: ContractState, pool_member: ContractAddress) -> u128 {
            let mut pool_member_info = self.get_pool_member_info(pool_member);
            let rewards = 100_000_000_000_000_000_000; //100 STRK for reward
            pool_member_info.unclaimed_rewards = 0;
            self.pool_member_info.write(pool_member, Option::Some(pool_member_info));


            // Transfer STRK tokens back to pool member
            let strk_token = self.strk_token.read();
            strk_token.transfer(pool_member, rewards.into());

            self
                .emit(
                    PoolMemberRewardClaimed {
                        pool_member,
                        reward_address: pool_member_info.reward_address,
                        amount: rewards
                    }
                );
            rewards
        }

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
            assert(self.final_staker_index.read().is_none(), 'FINAL_STAKER_INDEX_ALREADY_SET');
            self.final_staker_index.write(Option::Some(final_staker_index));
            self
                .emit(
                    FinalIndexSet { staker_address: self.staker_address.read(), final_staker_index }
                );
        }

        fn total_pool_amount(self: @ContractState) -> u128 {
            self.total_pool_amount.read()
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn get_pool_member_info(
            self: @ContractState, pool_member: ContractAddress
        ) -> PoolMemberInfo {
            self.pool_member_info.read(pool_member).expect('POOL_MEMBER_DOES_NOT_EXIST')
        }
    }

    // Helper functions for testing
    #[external(v0)]
    fn set_pool_member_info(
        ref self: ContractState, pool_member: ContractAddress, info: PoolMemberInfo
    ) {
        self.pool_member_info.write(pool_member, Option::Some(info));
    }

    #[external(v0)]
    fn set_commission(ref self: ContractState, commission: u16) {
        self.commission.write(commission);
    }
}

