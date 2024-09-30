use starknet::ContractAddress;

#[starknet::interface]
trait IDelegator<TContractState> {
    fn delegate(ref self: TContractState, amount: u256);
    fn request_withdrawal(ref self: TContractState, amount: u256);
    fn process_withdrawal(ref self: TContractState) -> u256;
    fn collect_rewards(ref self: TContractState) -> u256;
    fn get_total_stake(self: @TContractState) -> u256;
    fn get_last_reward_claim_time(self: @TContractState) -> u64;
}