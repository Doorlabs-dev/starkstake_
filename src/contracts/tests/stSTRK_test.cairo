use super::test_utils::{TestSetup, setup, approve_and_deposit_in_stSTRK};
use snforge_std::{cheat_caller_address, CheatSpan, start_cheat_block_timestamp_global,};
use starknet::testing::{set_caller_address, set_contract_address, set_block_timestamp};
use stakestark_::interfaces::i_stake_stark::{
    IStakeStark, IStakeStarkDispatcher, IStakeStarkDispatcherTrait, IStakeStarkView,
    IStakeStarkViewDispatcher, IStakeStarkViewDispatcherTrait
};
use stakestark_::interfaces::i_stSTRK::{IstSTRK, IstSTRKDispatcher, IstSTRKDispatcherTrait};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use stakestark_::contracts::tests::mock::strk::{ISTRK, ISTRKDispatcher, ISTRKDispatcherTrait};

#[test]
fn test_stSTRK_initialization() {
    let setup = setup();

    assert(setup.lst.asset() == setup.strk_address, 'Wrong underlying asset');
    assert(setup.lst.total_assets() == 0, 'Initial assets should be 0');
    assert(setup.lst.shares_per_asset() == 1, 'Initial share ratio incorrect');
}

#[test]
fn test_stSTRK_deposit_and_mint() {
    let setup = setup();
    let deposit_amount: u256 = 100_000_000_000_000_000_000; // 100 STRK

    // Test preview_deposit
    let expected_shares = setup.lst.preview_deposit(deposit_amount);

    // Perform deposit
    let actual_shares = approve_and_deposit_in_stSTRK(setup, setup.user, deposit_amount);
    assert(actual_shares == expected_shares, 'Share calculation mismatch');

    // Verify conversion rates
    let assets = setup.lst.convert_to_assets(actual_shares);
    assert(assets == deposit_amount, 'Asset conversion incorrect');
}

#[test]
fn test_stSTRK_rebase() {
    let setup = setup();
    let initial_deposit: u256 = 100_000_000_000_000_000_000; // 100 STRK

    // Initial deposit
    let initial_shares = approve_and_deposit_in_stSTRK(setup, setup.user, initial_deposit);

    // Simulate rewards (10% increase)
    let new_total_assets = initial_deposit + (initial_deposit / 10);

    // Perform rebase
    cheat_caller_address(setup.lst_address, setup.stake_stark_contact, CheatSpan::TargetCalls(1));
    setup.lst.rebase(new_total_assets);

    // Verify new conversion rates
    let final_assets = setup.lst.convert_to_assets(initial_shares);
    assert(final_assets > initial_deposit, 'Rebase should increase assets');
}

#[test]
fn test_max_deposit() {
    let setup = setup();

    // Test max deposit when not paused
    let max_deposit = setup.lst.max_deposit(setup.user);
    assert(max_deposit > 0, 'Max deposit should be non-zero');

    // Test max deposit when paused
    cheat_caller_address(setup.lst_address, setup.stake_stark_contact, CheatSpan::TargetCalls(3));
    setup.lst.pause();
    let max_deposit_paused = setup.lst.max_deposit(setup.user);
    assert(max_deposit_paused == 0, 'Max deposit must 0 when paused');

    // Unpause for other tests
    setup.lst.unpause();
}

#[test]
fn test_max_mint() {
    let setup = setup();

    let max_mint = setup.lst.max_mint(setup.user);
    assert(max_mint > 0, 'Max mint should be non-zero');

    // Test after some minting
    let mint_amount = 1000000000000000000; // 1 STRK worth of shares
    cheat_caller_address(setup.lst_address, setup.stake_stark_contact, CheatSpan::TargetCalls(1));
    setup.lst.mint(mint_amount, setup.user);

    let new_max_mint = setup.lst.max_mint(setup.user);
    assert(new_max_mint < max_mint, 'Max mint should decrease');
}

#[test]
fn test_preview_mint() {
    let setup = setup();
    let mint_shares: u256 = 100_000_000_000_000_000_000;

    // Test initial preview (when total supply is 0)
    let initial_assets = setup.lst.preview_mint(mint_shares);
    assert(initial_assets == mint_shares, 'Initial preview incorrect');

    // Test preview after some minting
    approve_and_deposit_in_stSTRK(setup, setup.user, 50_000_000_000_000_000_000);
    let new_preview = setup.lst.preview_mint(mint_shares);
    assert(new_preview > 0, 'Preview should be non-zero');
}

#[test]
fn test_max_withdraw() {
    let setup = setup();
    let deposit_amount: u256 = 100_000_000_000_000_000_000;

    // Test max withdraw before any deposits
    let initial_max_withdraw = setup.lst.max_withdraw(setup.user);
    assert(initial_max_withdraw == 0, 'Initial max withdraw must be 0');

    // Test after deposit
    approve_and_deposit_in_stSTRK(setup, setup.user, deposit_amount);
    let new_max_withdraw = setup.lst.max_withdraw(setup.user);
    assert(new_max_withdraw == deposit_amount, 'Max withdraw incorrect');
}

#[test]
fn test_preview_withdraw() {
    let setup = setup();
    let deposit_amount: u256 = 100_000_000_000_000_000_000;

    // Test preview withdraw when total assets is 0
    let initial_shares = setup.lst.preview_withdraw(deposit_amount);
    assert(initial_shares == 0, 'Initial preview should be 0');

    // Test after deposit
    approve_and_deposit_in_stSTRK(setup, setup.user, deposit_amount);
    let withdraw_shares = setup.lst.preview_withdraw(deposit_amount);
    assert(withdraw_shares > 0, 'Preview withdraw incorrect');
}

#[test]
fn test_max_redeem() {
    let setup = setup();
    let deposit_amount: u256 = 100_000_000_000_000_000_000;

    // Test max redeem before any deposits
    let initial_max_redeem = setup.lst.max_redeem(setup.user);
    assert(initial_max_redeem == 0, 'Initial max redeem should be 0');

    // Test after deposit
    let shares = approve_and_deposit_in_stSTRK(setup, setup.user, deposit_amount);
    let new_max_redeem = setup.lst.max_redeem(setup.user);
    assert(new_max_redeem == shares, 'Max redeem incorrect');
}

#[test]
fn test_preview_redeem() {
    let setup = setup();
    let shares: u256 = 100_000_000_000_000_000_000;

    // Test preview redeem
    let assets = setup.lst.preview_redeem(shares);
    assert(assets == shares, 'Initial preview redeem wrong');

    // Test after rebase
    approve_and_deposit_in_stSTRK(setup, setup.user, shares);
    cheat_caller_address(setup.lst_address, setup.stake_stark_contact, CheatSpan::TargetCalls(1));
    setup.lst.rebase(shares * 2); // Double the assets

    let new_assets = setup.lst.preview_redeem(shares);
    assert(new_assets > shares, 'Prev redeem after rebase wrong');
}

#[test]
fn test_multiple_rebases() {
    let setup = setup();
    let initial_deposit: u256 = 100_000_000_000_000_000_000;

    let shares = approve_and_deposit_in_stSTRK(setup, setup.user, initial_deposit);

    // First rebase (10% increase)
    let first_total = initial_deposit + (initial_deposit / 10);
    cheat_caller_address(setup.lst_address, setup.stake_stark_contact, CheatSpan::TargetCalls(2));
    setup.lst.rebase(first_total);

    // Second rebase (another 10% increase)
    let second_total = first_total + (first_total / 10);
    setup.lst.rebase(second_total);

    let final_assets = setup.lst.convert_to_assets(shares);
    assert(final_assets > first_total, 'Multiple rebases failed');
}

#[test]
#[should_panic(expected: ('Deposit amount too low',))]
fn test_deposit_zero_shares() {
    let setup = setup();
    let tiny_amount: u256 = 1; // Amount that would result in 0 shares
    approve_and_deposit_in_stSTRK(setup, setup.user, tiny_amount);
}

#[test]
#[should_panic(expected: ('ZERO_ASSETS',))]
fn test_mint_zero_assets() {
    let setup = setup();
    cheat_caller_address(setup.lst_address, setup.stake_stark_contact, CheatSpan::TargetCalls(1));
    setup.lst.mint(0, setup.user);
}

#[test]
fn test_shares_per_asset_after_multiple_operations() {
    let setup = setup();
    let initial_deposit: u256 = 100_000_000_000_000_000_000;

    // Initial deposit
    approve_and_deposit_in_stSTRK(setup, setup.user, initial_deposit);
    let initial_ratio = setup.lst.shares_per_asset();

    // Rebase with rewards
    cheat_caller_address(setup.lst_address, setup.stake_stark_contact, CheatSpan::TargetCalls(1));
    setup.lst.rebase(initial_deposit * 2);
    let after_rebase_ratio = setup.lst.shares_per_asset();

    assert(after_rebase_ratio < initial_ratio, 'Ratio should lower after rebase');
}

#[test]
fn test_burn_mechanism() {
    let setup = setup();
    let deposit_amount: u256 = 100_000_000_000_000_000_000;

    // Initial deposit
    let shares = approve_and_deposit_in_stSTRK(setup, setup.user, deposit_amount);

    // Burn shares
    cheat_caller_address(setup.lst_address, setup.stake_stark_contact, CheatSpan::TargetCalls(1));
    setup.lst.burn(shares / 2, setup.user);

    let remaining_shares = IERC20Dispatcher { contract_address: setup.lst_address }
        .balance_of(setup.user);
    assert(remaining_shares == shares / 2, 'Burn mechanism failed');
}

#[test]
#[should_panic(expected: ('Pausable: paused',))]
fn test_operations_when_paused() {
    let setup = setup();
    let deposit_amount: u256 = 100_000_000_000_000_000_000;

    // Pause the contract
    cheat_caller_address(setup.lst_address, setup.stake_stark_contact, CheatSpan::TargetCalls(1));
    setup.lst.pause();

    // Try to deposit while paused
    approve_and_deposit_in_stSTRK(setup, setup.user, deposit_amount);
}
