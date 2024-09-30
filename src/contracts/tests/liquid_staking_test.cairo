// tests/liquid_staking_test.cairo

use core::option::OptionTrait;
use core::result::ResultTrait;
use core::traits::Into;
use core::array::ArrayTrait;

use starknet::{
    ContractAddress, ClassHash, get_caller_address, get_contract_address, get_block_timestamp, contract_address_const, class_hash_const
};
use starknet::testing::{set_caller_address, set_contract_address, set_block_timestamp};

use stake_stark::interfaces::i_liquid_staking::{
    ILiquidStaking, ILiquidStakingDispatcher, ILiquidStakingDispatcherTrait,
    ILiquidStakingView, ILiquidStakingViewDispatcher, ILiquidStakingViewDispatcherTrait,
    FeeStrategy, WithdrawalRequest
};
use stake_stark::contracts::liquid_staking::LiquidStakingProtocol;

use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use stake_stark::interfaces::i_ls_token::{ILSTokenDispatcher, ILSTokenDispatcherTrait};
use stake_stark::interfaces::i_delegator::{IDelegatorDispatcher, IDelegatorDispatcherTrait};

use stake_stark::utils::constants::{ADMIN_ROLE, LIQUID_STAKING_ROLE, ONE_DAY};

// 테스트를 위한 헬퍼 함수
fn deploy_contract() -> (ContractAddress, ILiquidStakingDispatcher, ILiquidStakingViewDispatcher) {
    let caller = contract_address_const::<'caller'>();
    set_caller_address(caller);

    let ls_token = contract_address_const::<'ls_token'>();
    let strk_address = contract_address_const::<'strk'>();
    let pool_contract = contract_address_const::<'pool'>();
    let admin = contract_address_const::<'admin'>();
    let delegator_class_hash = class_hash_const::<'delegator'>();
    let initial_platform_fee: u16 = 500; // 5%
    let platform_fee_recipient = contract_address_const::<'fee_recipient'>();
    let initial_withdrawal_window_period: u64 = ONE_DAY;

    let contract_address = contract_address_const::<'liquid_staking'>();
    set_contract_address(contract_address);

    let mut calldata = ArrayTrait::new();
    calldata.append(ls_token.into());
    calldata.append(strk_address.into());
    calldata.append(pool_contract.into());
    calldata.append(admin.into());
    calldata.append(delegator_class_hash.into());
    calldata.append(initial_platform_fee.into());
    calldata.append(platform_fee_recipient.into());
    calldata.append(initial_withdrawal_window_period.into());

    let (contract_address, _) = starknet::deploy_syscall(
        LiquidStakingProtocol::TEST_CLASS_HASH.try_into().unwrap(),
        0,
        calldata.span(),
        false
    ).unwrap();

    (
        contract_address,
        ILiquidStakingDispatcher { contract_address },
        ILiquidStakingViewDispatcher { contract_address }
    )
}

#[test]
fn test_deposit() {
    let (contract_address, dispatcher, view_dispatcher) = deploy_contract();

    let user = contract_address_const::<'user'>();
    set_caller_address(user);

    let deposit_amount: u256 = 1000000000000000000; // 1 STRK
    let shares = dispatcher.deposit(deposit_amount);

    assert(shares > 0, 'Should receive shares');
    assert(view_dispatcher.get_pending_deposits() == deposit_amount, 'Invalid pending deposits');
}

#[test]
#[should_panic]
fn test_deposit_amount_too_low() {
    let (contract_address, dispatcher, _) = deploy_contract();

    let user = contract_address_const::<'user'>();
    set_caller_address(user);

    let deposit_amount: u256 = 1000000000000000; // 0.001 STRK
    dispatcher.deposit(deposit_amount);
}

#[test]
fn test_request_withdrawal() {
    let (contract_address, dispatcher, view_dispatcher) = deploy_contract();

    let user = contract_address_const::<'user'>();
    set_caller_address(user);

    let deposit_amount: u256 = 1000000000000000000; // 1 STRK
    let shares = dispatcher.deposit(deposit_amount);

    dispatcher.request_withdrawal(shares / 2);

    assert(view_dispatcher.get_pending_withdrawals() == deposit_amount / 2, 'Invalid pending withdrawals');
}

#[test]
fn test_withdraw() {
    let (contract_address, dispatcher, view_dispatcher) = deploy_contract();

    let user = contract_address_const::<'user'>();
    set_caller_address(user);

    let deposit_amount: u256 = 1000000000000000000; // 1 STRK
    let shares = dispatcher.deposit(deposit_amount);

    dispatcher.request_withdrawal(shares);

    // 출금 대기 기간 경과
    set_block_timestamp(get_block_timestamp() + ONE_DAY + 1);

    let mut request_ids = ArrayTrait::new();
    request_ids.append(0);
    dispatcher.withdraw(request_ids);

    assert(view_dispatcher.get_pending_withdrawals() == 0, 'Pending withdrawals should be 0');
}

#[test]
fn test_process_batch() {
    let (contract_address, dispatcher, view_dispatcher) = deploy_contract();

    let admin = contract_address_const::<'admin'>();
    set_caller_address(admin);

    let user = contract_address_const::<'user'>();
    set_caller_address(user);

    let deposit_amount: u256 = 1000000000000000000; // 1 STRK
    let shares = dispatcher.deposit(deposit_amount);

    dispatcher.request_withdrawal(shares / 2);

    set_caller_address(admin);
    dispatcher.process_batch();

    assert(view_dispatcher.get_pending_deposits() == 0, 'Pending deposits should be 0');
    assert(view_dispatcher.get_pending_withdrawals() == 0, 'Pending withdrawals should be 0');
}

#[test]
fn test_set_fee_strategy() {
    let (contract_address, dispatcher, view_dispatcher) = deploy_contract();

    let admin = contract_address_const::<'admin'>();
    set_caller_address(admin);

    let new_strategy = FeeStrategy::Tiered((100, 200, 1000000000000000000)); // 1%, 2%, 1 STRK threshold
    dispatcher.set_fee_strategy(new_strategy);

    assert(view_dispatcher.get_fee_strategy() == new_strategy, 'Fee strategy not updated');
}

#[test]
#[should_panic(expected: ("Caller is missing role",))]
fn test_set_fee_strategy_unauthorized() {
    let (contract_address, dispatcher, _) = deploy_contract();

    let user = contract_address_const::<'user'>();
    set_caller_address(user);

    let new_strategy = FeeStrategy::Flat(300);
    dispatcher.set_fee_strategy(new_strategy);
}