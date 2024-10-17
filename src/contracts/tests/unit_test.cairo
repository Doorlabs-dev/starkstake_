use core::array::ArrayTrait;
use core::result::ResultTrait;
use starknet::{ContractAddress, ClassHash, get_caller_address, get_block_timestamp};
use snforge_std::{
    declare, DeclareResultTrait, ContractClassTrait, cheat_caller_address, CheatSpan, ContractClass,
    EventSpy, start_cheat_block_timestamp_global, stop_cheat_block_timestamp_global
};
use starknet::class_hash::class_hash_const;

use stakestark_::interfaces::i_stake_stark::{
    IStakeStark, IStakeStarkDispatcher, IStakeStarkDispatcherTrait, IStakeStarkView,
    IStakeStarkViewDispatcher, IStakeStarkViewDispatcherTrait
};
use stakestark_::interfaces::i_stSTRK::{IstSTRK, IstSTRKDispatcher, IstSTRKDispatcherTrait};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use stakestark_::contracts::tests::mock::staking::{
    IMockStaking, IMockStakingDispatcher, IMockStakingDispatcherTrait
};
use stakestark_::contracts::tests::mock::pool::{
    IMockPool, IMockPoolDispatcher, IMockPoolDispatcherTrait
};
use stakestark_::contracts::tests::mock::strk::{ISTRK, ISTRKDispatcher, ISTRKDispatcherTrait};

// Constants
const INITIAL_SUPPLY: u256 = 1_000_000_000_000_000_000_000_000; // 1,000,000 STRK
const MIN_STAKE: u128 = 10_000_000_000_000_000_000; // 10 STRK
const EXIT_WAIT_WINDOW: u64 = 86400; // 1 day

// Test setup structure
#[derive(Drop)]
struct TestSetup {
    strk: ISTRKDispatcher,
    strk_address: ContractAddress,
    staking: IMockStakingDispatcher,
    pool: IMockPoolDispatcher,
    stake_stark_contact: ContractAddress,
    stake_stark: IStakeStarkDispatcher,
    stake_stark_view: IStakeStarkViewDispatcher,
    lst_address: ContractAddress,
    user: ContractAddress,
    admin: ContractAddress,
}

#[test]
fn test_initial_state() {
    let setup = deploy_and_setup();

    let total_assets = IstSTRKDispatcher { contract_address: setup.lst_address }.total_assets();
    assert!(total_assets == 0, "Initial totalassets should be 0");

    let platform_fee_recipient = setup.stake_stark_view.get_platform_fee_recipient();
    assert!(
        platform_fee_recipient == starknet::contract_address_const::<'fee_recipient'>(),
        "Incorrect fee recipient"
    );

    let unavailability_period = setup.stake_stark_view.get_unavailability_period();
    assert!(unavailability_period == EXIT_WAIT_WINDOW, "Incorrect unavailability period");
}

#[test]
fn test_deposit() {
    let setup = deploy_and_setup();
    let deposit_amount: u256 = 50_000_000_000_000_000_000; // 50 STRK

    let initial_strk_balance = setup.strk.balance_of(setup.user);
    let initial_lst_balance = IERC20Dispatcher { contract_address: setup.lst_address }
        .balance_of(setup.user);

    cheat_caller_address(setup.strk_address, setup.user, CheatSpan::TargetCalls(1));
    setup.strk.approve(setup.stake_stark.contract_address, deposit_amount);

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    let shares = setup.stake_stark.deposit(deposit_amount, setup.user);

    assert!(shares > 0, "Deposit should return shares");
    assert!(
        shares == IERC20Dispatcher { contract_address: setup.lst_address }.balance_of(setup.user)
            - initial_lst_balance,
        "Incorrect LST balance increase"
    );
    assert!(
        setup.strk.balance_of(setup.user) == initial_strk_balance - deposit_amount,
        "Incorrect STRK balance decrease"
    );

    let pending_deposits = setup.stake_stark_view.get_pending_deposits();
    assert!(pending_deposits == deposit_amount, "Incorrect pending deposits");
}

#[test]
#[should_panic]
fn test_deposit_less_than_minimum() {
    let setup = deploy_and_setup();
    let small_deposit: u256 = 1_000_000_000_000_000; // 0.001 STRK

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.deposit(small_deposit, setup.user);
}

#[test]
#[should_panic(expected: ('Transfer failed',))]
fn test_deposit_more_than_balance() {
    let setup = deploy_and_setup();
    let large_deposit: u256 = setup.strk.balance_of(setup.user) + 1;

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.deposit(large_deposit, setup.user);
}

#[test]
#[should_panic(expected: ('Pausable: paused',))]
fn test_deposit_when_paused() {
    let setup = deploy_and_setup();

    cheat_caller_address(setup.stake_stark_contact, setup.admin, CheatSpan::TargetCalls(1));
    setup.stake_stark.pause();

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.deposit(50_000_000_000_000_000_000, setup.user);
}

#[test]
fn test_request_withdrawal() {
    let setup = deploy_and_setup();
    let withdrawal_shares: u256 = 25_000_000_000_000_000_000; // 25 STRK worth of shares

    let initial_lst_balance = IERC20Dispatcher { contract_address: setup.lst_address }
        .balance_of(setup.user);

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.request_withdrawal(withdrawal_shares);

    let pending_withdrawals = setup.stake_stark_view.get_pending_withdrawals();
    assert!(pending_withdrawals > 0, "No pending withdrawals");

    let withdrawal_requests = setup.stake_stark_view.get_all_withdrawal_requests(setup.user);
    assert!(withdrawal_requests.len() > 0, "No withdrawal requests");

    assert!(
        IERC20Dispatcher { contract_address: setup.lst_address }
            .balance_of(setup.user) == initial_lst_balance
            - withdrawal_shares,
        "LST balance not decreased"
    );
}

#[test]
#[should_panic(expected: "ERC20: burn amount exceeds balance")]
fn test_request_withdrawal_more_than_balance() {
    let setup = deploy_and_setup();
    let excess_shares: u256 = IERC20Dispatcher { contract_address: setup.lst_address }
        .balance_of(setup.user)
        + 1;

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.request_withdrawal(excess_shares);
}

#[test]
#[should_panic(expected: ('Withdrawal amount too small',))]
fn test_request_withdrawal_zero_shares() {
    let setup = deploy_and_setup();

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.request_withdrawal(0);
}

#[test]
fn test_process_batch() {
    let setup = deploy_and_setup();

    let deposit_amount: u256 = 100; // 100 STRK

    cheat_caller_address(setup.strk_address, setup.user, CheatSpan::TargetCalls(1));
    setup.strk.approve(setup.stake_stark.contract_address, 100000);

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(5));
    setup.stake_stark.deposit(deposit_amount, setup.user);
    setup.stake_stark.deposit(deposit_amount, setup.user);
    setup.stake_stark.deposit(deposit_amount, setup.user);
    setup.stake_stark.deposit(deposit_amount, setup.user);
    setup.stake_stark.request_withdrawal(deposit_amount);

    let initial_pending_deposits = setup.stake_stark_view.get_pending_deposits();
    let initial_pending_withdrawals = setup.stake_stark_view.get_pending_withdrawals();

    cheat_caller_address(setup.stake_stark_contact, setup.admin, CheatSpan::TargetCalls(1));
    setup.stake_stark.process_batch();

    let final_pending_deposits = setup.stake_stark_view.get_pending_deposits();
    let final_pending_withdrawals = setup.stake_stark_view.get_pending_withdrawals();

    assert!(final_pending_deposits == 0, "Pending deposits not processed");
    assert!(final_pending_withdrawals == 0, "Pending withdraws not processed");

    let total_delegated = setup.pool.total_pool_amount();

    assert!(
        total_delegated == initial_pending_deposits.try_into().unwrap()
            - initial_pending_withdrawals.try_into().unwrap(),
        "Incorrect delegation amount"
    );
}

#[test]
fn test_process_batch_no_pending() {
    let setup = deploy_and_setup();

    cheat_caller_address(setup.stake_stark_contact, setup.admin, CheatSpan::TargetCalls(1));
    setup.stake_stark.process_batch();
    // This should not cause any errors and should essentially be a no-op
}

#[test]
#[should_panic(expected: ('Caller is not an operator',))]
fn test_process_batch_non_admin() {
    let setup = deploy_and_setup();

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.process_batch();
}

#[test]
fn test_withdraw() {
    let setup = deploy_and_setup();

    // Advance time to make withdrawal requests available
    start_cheat_block_timestamp_global(get_block_timestamp() + EXIT_WAIT_WINDOW + 1);

    let initial_strk_balance = setup.strk.balance_of(setup.user);
    let available_requests = setup
        .stake_stark_view
        .get_available_withdrawal_requests(setup.user);
    assert!(available_requests.len() > 0, "No available withdrawals");

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.withdraw();

    let new_available_requests = setup
        .stake_stark_view
        .get_available_withdrawal_requests(setup.user);
    assert!(new_available_requests.len() < available_requests.len(), "Withdrawal not processed");

    let final_strk_balance = setup.strk.balance_of(setup.user);
    assert!(
        final_strk_balance > initial_strk_balance, "STRK not increased after withd"
    );

    stop_cheat_block_timestamp_global();
}

#[test]
#[should_panic(expected: ('No withdrawable requests',))]
fn test_withdraw_before_exit_window() {
    let setup = deploy_and_setup();

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.withdraw();
}

#[test]
#[should_panic(expected: ('No withdrawable requests',))]
fn test_withdraw_no_pending_requests() {
    let setup = deploy_and_setup();

    start_cheat_block_timestamp_global(get_block_timestamp() + EXIT_WAIT_WINDOW + 1);

    cheat_caller_address(setup.stake_stark_contact, setup.admin, CheatSpan::TargetCalls(1));
    setup.stake_stark.withdraw();

    stop_cheat_block_timestamp_global();
}


fn deploy_and_setup() -> TestSetup {
    // Deploy mock STRK token
    let strk_contract = deploy_mock_strk();
    let strk = ISTRKDispatcher { contract_address: strk_contract };

    // Deploy mock staking contract
    let (staking_contract, staking) = deploy_mock_staking(strk_contract);

    // Stake to get a pool contract
    let admin = starknet::contract_address_const::<'admin'>();
    let user = starknet::contract_address_const::<'user'>();
    let stake_amount: u128 = 100_000_000_000_000_000_000; // 100 STRK

    // Mint some STRK to the admin
    strk.mint(admin, stake_amount.into());
    strk.mint(user, 10000);

    // Admin approves and stakes
    cheat_caller_address(strk_contract, admin, CheatSpan::TargetCalls(1));
    strk.approve(staking_contract, stake_amount.into());

    cheat_caller_address(staking_contract, admin, CheatSpan::TargetCalls(1));
    staking.stake(admin, admin, stake_amount, true, 500); // 5% commission

    // Get pool contract address
    let pool_contract = staking.get_deployed_pool(admin);
    strk.mint(pool_contract, 100_000_000_000_000_000_000_000_000);

    let pool = IMockPoolDispatcher { contract_address: pool_contract };

    // Deploy liquid staking contract
    let (stake_stark_contact, stake_stark, stake_stark_view) = deploy_stake_stark(
        strk_contract, pool_contract
    );
    let lst_address = stake_stark_view.get_lst_address();

    // Mint some STRK to the user for testing
    //strk.mint(user, (stake_amount * 2).into());
    TestSetup {
        strk,
        strk_address: strk_contract,
        staking,
        pool,
        stake_stark_contact,
        stake_stark,
        stake_stark_view,
        lst_address,
        user,
        admin,
    }
}

// Helper function to deploy mock STRK token
fn deploy_mock_strk() -> ContractAddress {
    let contract = declare("MockSTRK").unwrap().contract_class();
    let mut calldata = ArrayTrait::new();
    let name: felt252 = 'Starknet Token';
    let symbol: felt252 = 'STRK';

    calldata.append(name);
    calldata.append(symbol);
    INITIAL_SUPPLY.serialize(ref calldata);
    starknet::contract_address_const::<'admin'>().serialize(ref calldata);

    let (contract_address, _) = contract.deploy(@calldata).unwrap();
    contract_address
}

// Helper function to deploy mock staking contract
fn deploy_mock_staking(strk_address: ContractAddress) -> (ContractAddress, IMockStakingDispatcher) {
    let contract = declare("MockStaking").unwrap().contract_class();
    let pool = declare("MockPool").unwrap().contract_class();
    let mut calldata = ArrayTrait::new();

    MIN_STAKE.serialize(ref calldata);
    EXIT_WAIT_WINDOW.serialize(ref calldata);
    pool.class_hash.serialize(ref calldata); // Dummy class hash for pool contract
    strk_address.serialize(ref calldata);

    let (contract_address, _) = contract.deploy(@calldata).unwrap();
    (contract_address, IMockStakingDispatcher { contract_address })
}

// Helper function to deploy liquid staking contract
fn deploy_stake_stark(
    strk_address: ContractAddress, pool_contract: ContractAddress
) -> (ContractAddress, IStakeStarkDispatcher, IStakeStarkViewDispatcher) {
    let contract = declare("StakeStark").unwrap().contract_class();
    let delegator = declare("Delegator").unwrap().contract_class();
    let stSTRK = declare("stSTRK").unwrap().contract_class();

    let admin = starknet::contract_address_const::<'admin'>();
    let initial_platform_fee: u16 = 500; // 5%
    let platform_fee_recipient = starknet::contract_address_const::<'fee_recipient'>();
    let initial_withdrawal_window_period: u64 = 300;

    let mut calldata = ArrayTrait::new();
    strk_address.serialize(ref calldata);
    pool_contract.serialize(ref calldata);
    delegator.class_hash.serialize(ref calldata);
    22.serialize(ref calldata);
    stSTRK.class_hash.serialize(ref calldata);
    initial_platform_fee.serialize(ref calldata);
    platform_fee_recipient.serialize(ref calldata);
    initial_withdrawal_window_period.serialize(ref calldata);
    admin.serialize(ref calldata);
    admin.serialize(ref calldata);

    let (contract_address, _) = contract.deploy(@calldata).unwrap();

    (
        contract_address,
        IStakeStarkDispatcher { contract_address },
        IStakeStarkViewDispatcher { contract_address }
    )
}
