use super::test_utils::{
    setup, approve_and_deposit, approve_and_deposit_in_stSTRK, request_withdrawal, process_batch,
    EXIT_WAIT_WINDOW
};
use snforge_std::{
    cheat_caller_address, CheatSpan, start_cheat_block_timestamp_global,
    stop_cheat_block_timestamp_global
};
use stakestark_::interfaces::i_stake_stark::{
    IStakeStark, IStakeStarkDispatcher, IStakeStarkDispatcherTrait, IStakeStarkView,
    IStakeStarkViewDispatcher, IStakeStarkViewDispatcherTrait
};
use stakestark_::interfaces::i_stSTRK::{IstSTRK, IstSTRKDispatcher, IstSTRKDispatcherTrait};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use stakestark_::contracts::tests::mock::strk::{ISTRK, ISTRKDispatcher, ISTRKDispatcherTrait};
use starknet::get_block_timestamp;

#[test]
fn test_full_stake_unstake_cycle() {
    let setup = setup();
    let deposit_amount: u256 = 100_000_000_000_000_000_000; // 100 STRK

    // 1. Deposit
    let shares = approve_and_deposit(setup, setup.user, deposit_amount);

    // 2. Request withdrawal
    request_withdrawal(setup, setup.user, shares);

    // 3. Process batch
    process_batch(setup);

    // 4. Wait for exit window
    start_cheat_block_timestamp_global(get_block_timestamp() + EXIT_WAIT_WINDOW + 1);
    process_batch(setup);

    // 5. Withdraw
    let initial_balance = setup.strk.balance_of(setup.user);
    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.withdraw();

    // 6. Verify final state
    let final_balance = setup.strk.balance_of(setup.user);
    assert(final_balance > initial_balance, 'Withdrawal failed');
}