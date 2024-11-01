use super::test_utils::{
    TestSetup, setup, EXIT_WAIT_WINDOW, request_withdrawal, approve_and_deposit, process_batch
};

use core::array::ArrayTrait;
use core::result::ResultTrait;
use starknet::get_block_timestamp;
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

#[test]
fn test_stake_stark_system_overall() {
    let setup = setup();

    test_deposit(setup);
    test_request_withdrawal(setup);
    test_process_batch(setup);
    test_withdraw(setup);
}

fn test_deposit(setup: TestSetup) {
    let deposit_amount: u256 = 50_000_000_000_000_000_000; // 50 STRK

    let shares = approve_and_deposit(setup, setup.user, deposit_amount);

    //assert(shares == IERC20Dispatcher{contract_address:
    //setup.lst_address}.balance_of(setup.user),'share is not correct');
    assert(shares > 0, 'Deposit should return shares');

    let pending_deposits = setup.stake_stark_view.get_pending_deposits();
    assert(pending_deposits == deposit_amount, 'Incorrect pending deposits');
}

fn test_request_withdrawal(setup: TestSetup) {
    let withdrawal_shares: u256 = 25_000_000_000_000_000_000; // 25 STRK worth of shares

    request_withdrawal(setup, setup.user, withdrawal_shares);

    let pending_withdrawals = setup.stake_stark_view.get_pending_withdrawals();
    assert(pending_withdrawals > 0, 'No pending withdrawals');

    let withdrawal_requests = setup.stake_stark_view.get_all_withdrawal_requests(setup.user);
    assert(withdrawal_requests.len() > 0, 'No withdrawal requests');
}

fn test_process_batch(setup: TestSetup) {
    process_batch(setup);

    let pending_deposits = setup.stake_stark_view.get_pending_deposits();
    let pending_withdrawals = setup.stake_stark_view.get_pending_withdrawals();

    assert(pending_deposits == 0, 'Pending deposits not processed');
    assert(pending_withdrawals == 0, 'Pending withdraw not processed');
}

fn test_withdraw(setup: TestSetup) {
    // Advance time to make withdrawal requests available
    start_cheat_block_timestamp_global(get_block_timestamp() + EXIT_WAIT_WINDOW + 1);

    let available_requests = setup.stake_stark_view.get_available_withdrawal_requests(setup.user);
    assert(available_requests.len() > 0, 'No available withdrawals');

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.withdraw();

    let new_available_requests = setup
        .stake_stark_view
        .get_available_withdrawal_requests(setup.user);
    assert(new_available_requests.len() < available_requests.len(), 'Withdrawal not processed');
    stop_cheat_block_timestamp_global();
}

#[test]
fn test_multiple_deposits_and_withdrawals() {
    let setup = setup();
    let mut total_shares: u256 = 0;
    let deposit_amount: u256 = 20_000_000_000_000_000_000; // 20 STRK
    let mut counter: u8 = 0;

    // Multiple deposits
    while counter < 5 {
        let shares = approve_and_deposit(setup, setup.user, deposit_amount);
        total_shares += shares;

        if counter == 2 {
            // Process batch in the middle
            cheat_caller_address(setup.stake_stark_contact, setup.admin, CheatSpan::TargetCalls(1));
            setup.stake_stark.process_batch();
        }
        counter += 1;
    };

    let pending_deposits = setup.stake_stark_view.get_pending_deposits();
    assert(pending_deposits == deposit_amount * 2, 'Incorrect pending deposits'); // Last 2 deposits

    let lst_balance = IERC20Dispatcher { contract_address: setup.lst_address }
        .balance_of(setup.user);
    assert(lst_balance == total_shares, 'Incorrect total shares');
}

#[test]
#[should_panic(expected: ('Insufficient available funds',))]
fn test_staggered_withdrawals() {
    let setup = setup();
    let deposit_amount: u256 = 100_000_000_000_000_000_000; // 100 STRK

    // Initial deposit
    let total_shares = approve_and_deposit(setup, setup.user, deposit_amount);

    // Process initial deposit
    process_batch(setup);

    // Request multiple withdrawals
    let withdrawal_shares = total_shares / 4; // 25% each time
    let mut counter: u8 = 0;
    while counter < 4 {
        request_withdrawal(setup, setup.user, withdrawal_shares);

        if counter == 1 {
            // Process batch after second withdrawal request
            cheat_caller_address(setup.stake_stark_contact, setup.admin, CheatSpan::TargetCalls(1));
            setup.stake_stark.process_batch();
        }
        counter += 1;
    };

    // Process remaining withdrawal requests
    process_batch(setup);

    // Try withdrawals at different times
    start_cheat_block_timestamp_global(get_block_timestamp() + EXIT_WAIT_WINDOW + 1);

    let mut withdraw_counter: u8 = 0;
    while withdraw_counter < 2 {
        cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
        setup.stake_stark.withdraw();
        withdraw_counter += 1;
    };

    // Advance time further and withdraw remaining
    start_cheat_block_timestamp_global(get_block_timestamp() + EXIT_WAIT_WINDOW + 1);

    withdraw_counter = 0;
    while withdraw_counter < 2 {
        cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
        setup.stake_stark.withdraw();
        withdraw_counter += 1;
    };

    stop_cheat_block_timestamp_global();
}

#[test]
fn test_deposit_withdraw_cycle_with_rewards() {
    let setup = setup();
    let deposit_amount: u256 = 50_000_000_000_000_000_000; // 50 STRK

    // Multiple deposits
    let mut total_shares: u256 = 0;
    let mut counter: u8 = 0;
    while counter < 3 {
        total_shares += approve_and_deposit(setup, setup.user, deposit_amount);
        counter += 1;
    };

    // Process batch and simulate rewards
    process_batch(setup);

    // Request partial withdrawal
    let withdrawal_shares = total_shares / 2;
    request_withdrawal(setup, setup.user, withdrawal_shares);

    // Process withdrawal request
    process_batch(setup);

    // Wait and withdraw
    start_cheat_block_timestamp_global(get_block_timestamp() + EXIT_WAIT_WINDOW + 1);

    process_batch(setup);
    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.withdraw();

    // Deposit again
    approve_and_deposit(setup, setup.user, deposit_amount);

    stop_cheat_block_timestamp_global();
}

#[test]
fn test_complex_batch_processing() {
    let setup = setup();
    let deposit_amount: u256 = 40_000_000_000_000_000_000; // 40 STRK

    // Multiple deposits without processing
    let mut total_shares: u256 = 0;
    let mut counter: u8 = 0;
    while counter < 3 {
        total_shares += approve_and_deposit(setup, setup.user, deposit_amount);
        counter += 1;
    };

    // Request withdrawals without processing deposits
    let withdrawal_shares = total_shares / 3;
    counter = 0;
    while counter < 2 {
        request_withdrawal(setup, setup.user, withdrawal_shares);
        counter += 1;
    };

    // Process everything
    process_batch(setup);

    // More deposits and withdrawals
    let new_shares = approve_and_deposit(setup, setup.user, deposit_amount);

    request_withdrawal(setup, setup.user, new_shares);

    // Process again
    process_batch(setup);

    // Verify final state
    let pending_deposits = setup.stake_stark_view.get_pending_deposits();
    let pending_withdrawals = setup.stake_stark_view.get_pending_withdrawals();
    assert(pending_deposits == 0, 'Pending deposits should be 0');
    assert(pending_withdrawals == 0, 'Pending withdrawals should be 0');
}
