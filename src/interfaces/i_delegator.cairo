use starknet::{ContractAddress, ClassHash};

mod Events {
    #[derive(Drop, starknet::Event)]
    struct Delegated {
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawalRequested {
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawalProcessed {
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct RewardsClaimed {
        amount: u256,
        processed_time: u64,
    }
}

#[starknet::interface]
trait IDelegator<TContractState> {
    fn delegate(ref self: TContractState, amount: u256);
    fn request_withdrawal(ref self: TContractState, amount: u256);
    fn process_withdrawal(ref self: TContractState) -> u256;
    fn collect_rewards(ref self: TContractState) -> u256;
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
    fn get_total_stake(self: @TContractState) -> u256;
}
