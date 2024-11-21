use starknet::{ContractAddress, ClassHash};

#[starknet::interface]
trait IStakedStrkToken<TContractState> {
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    fn burn(ref self: TContractState, value: u256);
    fn mint(ref self: TContractState, recipient: ContractAddress, amount: u256);
    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
}
