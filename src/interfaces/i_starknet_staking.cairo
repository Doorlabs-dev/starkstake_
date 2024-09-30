use starknet::{ContractAddress, ClassHash, get_block_timestamp};
use core::cmp::max;

#[derive(Debug, PartialEq, Drop, Serde, Copy, starknet::Store)]
pub struct StakerPoolInfo {
    pub pool_contract: ContractAddress,
    pub amount: u128,
    pub unclaimed_rewards: u128,
    pub commission: u16,
}

// TODO create a different struct for not exposing internal implemenation
#[derive(Debug, PartialEq, Drop, Serde, Copy, starknet::Store)]
pub struct StakerInfo {
    pub reward_address: ContractAddress,
    pub operational_address: ContractAddress,
    pub unstake_time: Option<u64>,
    pub amount_own: u128,
    pub index: u64,
    pub unclaimed_rewards_own: u128,
    pub pool_info: Option<StakerPoolInfo>,
}


#[derive(Copy, Debug, Drop, PartialEq, Serde)]
pub struct StakingContractInfo {
    pub min_stake: u128,
    pub token_address: ContractAddress,
    pub global_index: u64,
    pub pool_contract_class_hash: ClassHash,
    pub reward_supplier: ContractAddress,
    pub exit_wait_window: u64
}

/// Public interface for the staking contract.
/// This interface is exposed by the operator contract.
#[starknet::interface]
pub trait IStaking<TContractState> {
    fn stake(
        ref self: TContractState,
        reward_address: ContractAddress,
        operational_address: ContractAddress,
        amount: u128,
        pool_enabled: bool,
        commission: u16,
    ) -> bool;
    fn increase_stake(
        ref self: TContractState, staker_address: ContractAddress, amount: u128
    ) -> u128;
    fn claim_rewards(ref self: TContractState, staker_address: ContractAddress) -> u128;
    fn unstake_intent(ref self: TContractState) -> u64;
    fn unstake_action(ref self: TContractState, staker_address: ContractAddress) -> u128;
    fn change_reward_address(ref self: TContractState, reward_address: ContractAddress) -> bool;
    fn set_open_for_delegation(ref self: TContractState, commission: u16) -> ContractAddress;
    fn staker_info(self: @TContractState, staker_address: ContractAddress) -> StakerInfo;
    fn contract_parameters(self: @TContractState) -> StakingContractInfo;
    fn get_total_stake(self: @TContractState) -> u128;
    fn update_global_index_if_needed(ref self: TContractState) -> bool;
    fn change_operational_address(
        ref self: TContractState, operational_address: ContractAddress
    ) -> bool;
    // fn update_commission(ref self: TContractState, commission: u16) -> bool;
    fn is_paused(self: @TContractState) -> bool;
}

/// Interface for the staking pool contract.
/// All functions in this interface are called only by the pool contract.
#[starknet::interface]
pub trait IStakingPool<TContractState> {
    fn add_stake_from_pool(
        ref self: TContractState, staker_address: ContractAddress, amount: u128
    ) -> (u128, u64);
    fn remove_from_delegation_pool_intent(
        ref self: TContractState,
        staker_address: ContractAddress,
        identifier: felt252,
        amount: u128,
    ) -> u64;
    fn remove_from_delegation_pool_action(ref self: TContractState, identifier: felt252) -> u128;
    fn switch_staking_delegation_pool(
        ref self: TContractState,
        to_staker: ContractAddress,
        to_pool: ContractAddress,
        switched_amount: u128,
        data: Span<felt252>,
        identifier: felt252
    ) -> bool;
    fn claim_delegation_pool_rewards(
        ref self: TContractState, staker_address: ContractAddress
    ) -> u64;
}

#[starknet::interface]
pub trait IStakingPause<TContractState> {
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
}

pub mod PauseEvents {
    use starknet::ContractAddress;
    #[derive(Drop, starknet::Event)]
    pub struct Paused {
        pub account: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Unpaused {
        pub account: ContractAddress,
    }
}

#[starknet::interface]
pub trait IStakingConfig<TContractState> {
    fn set_min_stake(ref self: TContractState, min_stake: u128);
    fn set_exit_wait_window(ref self: TContractState, exit_wait_window: u64);
    fn set_reward_supplier(ref self: TContractState, reward_supplier: ContractAddress);
}


#[derive(Drop, PartialEq, Serde, Copy, starknet::Store, Debug)]
pub struct PoolMemberInfo {
    pub reward_address: ContractAddress,
    pub amount: u128,
    pub index: u64,
    pub unclaimed_rewards: u128,
    pub unpool_amount: u128,
    pub unpool_time: Option<u64>,
}

#[derive(Copy, Debug, Drop, PartialEq, Serde)]
pub struct PoolContractInfo {
    pub staker_address: ContractAddress,
    pub final_staker_index: Option<u64>,
    pub staking_contract: ContractAddress,
    pub token_address: ContractAddress,
    pub commission: u16,
}

#[starknet::interface]
pub trait IPool<TContractState> {
    fn enter_delegation_pool(
        ref self: TContractState, reward_address: ContractAddress, amount: u128
    ) -> bool;
    fn add_to_delegation_pool(
        ref self: TContractState, pool_member: ContractAddress, amount: u128
    ) -> u128;
    fn exit_delegation_pool_intent(ref self: TContractState, amount: u128);
    fn exit_delegation_pool_action(ref self: TContractState, pool_member: ContractAddress) -> u128;
    fn claim_rewards(ref self: TContractState, pool_member: ContractAddress) -> u128;
    fn switch_delegation_pool(
        ref self: TContractState, to_staker: ContractAddress, to_pool: ContractAddress, amount: u128
    ) -> u128;
    fn enter_delegation_pool_from_staking_contract(
        ref self: TContractState, amount: u128, index: u64, data: Span<felt252>
    ) -> bool;
    fn set_final_staker_index(ref self: TContractState, final_staker_index: u64);
    fn change_reward_address(ref self: TContractState, reward_address: ContractAddress) -> bool;
    fn pool_member_info(self: @TContractState, pool_member: ContractAddress) -> PoolMemberInfo;
    fn contract_parameters(self: @TContractState) -> PoolContractInfo;
    fn update_commission(ref self: TContractState, commission: u16) -> bool;
}
