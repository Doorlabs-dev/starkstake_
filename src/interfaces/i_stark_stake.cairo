use starknet::{ContractAddress, ClassHash};
#[derive(Drop, Serde, starknet::Store)]
struct WithdrawalRequest {
    assets: u256,
    withdrawal_time: u64,
}

mod Events {
    use super::ContractAddress;

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        #[key]
        sender: ContractAddress,
        #[key]
        owner: ContractAddress,
        assets: u256,
        shares: u256
    }

    #[derive(Drop, starknet::Event)]
    struct DelegatorWithdrew {
        id: u8,
        delegator: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawalRequested {
        user: ContractAddress,
        request_id: u32,
        shares: u256,
        assets: u256,
        withdrawal_time: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdraw {
        #[key]
        sender: ContractAddress,
        assets: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Rebased {
        old_total_assets: u256,
        new_total_assets: u256
    }

    #[derive(Drop, starknet::Event)]
    struct StSRTKDeployed {
        address: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct RewardDistributed {
        total_reward: u256,
        platform_fee_amount: u256,
        distributed_reward: u256
    }

    #[derive(Drop, starknet::Event)]
    struct DelegatorAdded {
        #[key]
        delegator: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct DelegatorStatusChanged {
        #[key]
        delegator: ContractAddress,
        status: bool,
        available_time: u64
    }

    #[derive(Drop, starknet::Event)]
    struct FeeRatioChanged {
        new_ratio: u16,
    }

    #[derive(Drop, starknet::Event)]
    struct UnavailabilityPeriodChanged {
        old_period: u64,
        new_period: u64
    }

    #[derive(Drop, starknet::Event)]
    struct DepositAddedInQueue {
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawalAddedInQueue {
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct BatchProcessed {
        net_deposit_amount: u256,
        net_withdrawal_amount: u256,
        timestamp: u64,
    }
}

#[starknet::interface]
trait IStarkStake<TContractState> {
    fn deposit(ref self: TContractState, assets: u256, receiver: ContractAddress) -> u256;
    fn mint(ref self: TContractState, shares: u256, receiver: ContractAddress) -> u256;
    fn request_withdrawal(ref self: TContractState, shares: u256);
    fn withdraw(ref self: TContractState) -> u256;
    fn process_batch(ref self: TContractState);

    fn rebase(ref self: TContractState, new_total_assets: u256);

    fn set_fee_ratio(ref self: TContractState, new_ratio: u16);
    fn set_platform_fee_recipient(ref self: TContractState, recipient: ContractAddress);
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    fn pause_stSTRK(ref self: TContractState);
    fn unpause_stSTRK(ref self: TContractState);
    fn pause_delegator(ref self: TContractState);
    fn unpause_delegator(ref self: TContractState);
    fn pause_all(ref self: TContractState);
    fn unpause_all(ref self: TContractState);

    fn set_unavailability_period(ref self: TContractState, new_period: u64);

    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
    fn upgrade_delegator(ref self: TContractState, new_class_hash: ClassHash);
    fn upgrade_stSTRK(ref self: TContractState, new_class_hash: ClassHash);
}

#[starknet::interface]
trait IStarkStakeView<TContractState> {
    fn asset(self: @TContractState) -> ContractAddress;
    fn total_assets(self: @TContractState) -> u256;
    fn convert_to_shares(self: @TContractState, assets: u256) -> u256;
    fn convert_to_assets(self: @TContractState, shares: u256) -> u256;
    fn max_deposit(self: @TContractState, receiver: ContractAddress) -> u256;
    fn preview_deposit(self: @TContractState, assets: u256) -> u256;
    fn max_mint(self: @TContractState, receiver: ContractAddress) -> u256;
    fn preview_mint(self: @TContractState, shares: u256) -> u256;
    fn max_withdraw(self: @TContractState, owner: ContractAddress) -> u256;
    fn preview_withdraw(self: @TContractState, assets: u256) -> u256;
    fn max_redeem(self: @TContractState, owner: ContractAddress) -> u256;
    fn preview_redeem(self: @TContractState, shares: u256) -> u256;
    fn shares_per_asset(self: @TContractState) -> u256;


    fn get_stSTRK_address(self: @TContractState) -> ContractAddress;
    fn get_delegators_address(self: @TContractState) -> Array<ContractAddress>;
    fn get_fee_ratio(self: @TContractState) -> u16;
    fn get_platform_fee_recipient(self: @TContractState) -> ContractAddress;
    fn get_withdrawable_amount(self: @TContractState, user: ContractAddress) -> u256;
    fn get_all_withdrawal_requests(
        self: @TContractState, user: ContractAddress
    ) -> Array<WithdrawalRequest>;
    fn get_available_withdrawal_requests(
        self: @TContractState, user: ContractAddress
    ) -> Array<(u32, WithdrawalRequest)>;
    fn get_unavailability_period(self: @TContractState) -> u64;
    fn get_pending_deposits(self: @TContractState) -> u256;
    fn get_pending_withdrawals(self: @TContractState) -> u256;
}
