use core::array::ArrayTrait;
use core::result::ResultTrait;
use starknet::{
    ContractAddress, ClassHash, get_caller_address, get_block_timestamp, SyscallResultTrait
};
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, ContractClass, cheat_caller_address, CheatSpan,
    start_cheat_block_timestamp_global, stop_cheat_block_timestamp_global,
    cheat_account_contract_address, start_cheat_caller_address_global,
    stop_cheat_caller_address_global
};
use starknet::class_hash::class_hash_const;
use starknet::testing::{set_caller_address, set_contract_address, set_block_timestamp};

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
#[derive(Copy, Clone, Drop)]
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
fn test_stake_stark_system() {
    let setup = deploy_and_setup();

    check_deployments(setup);
    println!("check_deployments done");
    test_lst_operations(setup);
    println!("test_lst_operations done");
    test_deposit(setup);
    println!("test_deposit done");
    test_request_withdrawal(setup);
    println!("test_request_withdrawal done");
    test_process_batch(setup);
    println!("test_process_batch done");
    test_withdraw(setup);
    println!("test_withdraw done");
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
    strk.mint(user, 100_000_000_000_000_000_000_000);

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
    strk.mint(user, (stake_amount * 2).into());
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

fn check_deployments(setup: TestSetup) {
    assert(setup.strk.contract_address.is_non_zero(), 'STRK not deployed');
    assert(setup.staking.contract_address.is_non_zero(), 'Staking not deployed');
    assert(setup.pool.contract_address.is_non_zero(), 'Pool not deployed');
    assert(setup.stake_stark.contract_address.is_non_zero(), 'StakeStark not deployed');
    assert(setup.lst_address.is_non_zero(), 'LST not deployed');
}

fn test_deposit(setup: TestSetup) {
    let deposit_amount: u256 = 50_000_000_000_000_000_000; // 50 STRK

    cheat_caller_address(setup.strk_address, setup.user, CheatSpan::TargetCalls(1));
    setup.strk.approve(setup.stake_stark.contract_address, deposit_amount);

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    let shares = setup.stake_stark.deposit(deposit_amount, setup.user, setup.user);

    //assert(shares == IERC20Dispatcher{contract_address:
    //setup.lst_address}.balance_of(setup.user),'share is not correct');
    assert(shares > 0, 'Deposit should return shares');

    let pending_deposits = setup.stake_stark_view.get_pending_deposits();
    assert(pending_deposits == deposit_amount, 'Incorrect pending deposits');
}

fn test_request_withdrawal(setup: TestSetup) {
    let withdrawal_shares: u256 = 25_000_000_000_000_000_000; // 25 STRK worth of shares

    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.stake_stark.request_withdrawal(withdrawal_shares);

    let pending_withdrawals = setup.stake_stark_view.get_pending_withdrawals();
    assert(pending_withdrawals > 0, 'No pending withdrawals');

    let withdrawal_requests = setup.stake_stark_view.get_all_withdrawal_requests(setup.user);
    assert(withdrawal_requests.len() > 0, 'No withdrawal requests');
}

fn test_process_batch(setup: TestSetup) {
    cheat_caller_address(setup.stake_stark_contact, setup.admin, CheatSpan::TargetCalls(1));
    setup.stake_stark.process_batch();

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

fn test_lst_operations(setup: TestSetup) {
    let lst_dispatcher = IstSTRKDispatcher { contract_address: setup.lst_address };
    let lst_erc20_dispatcher = IERC20Dispatcher { contract_address: setup.lst_address };
    // Test initial state
    let total_assets = lst_dispatcher.total_assets();
    assert(total_assets == 0, 'Init total assets should be 0');

    // Test deposit
    let deposit_amount: u256 = 50_000_000_000_000_000_000; // 50 STRK
    cheat_caller_address(setup.strk_address, setup.user, CheatSpan::TargetCalls(1));
    setup.strk.approve(setup.stake_stark_contact, deposit_amount);

    cheat_caller_address(setup.lst_address, setup.user, CheatSpan::TargetCalls(1));
    cheat_caller_address(setup.stake_stark_contact, setup.user, CheatSpan::TargetCalls(1));
    let shares = lst_dispatcher.deposit(deposit_amount, setup.user);

    // Check LST balance
    let lst_balance = lst_erc20_dispatcher.balance_of(setup.user);
    assert(lst_balance == shares, 'LST balance should match shares');

    // Test convert_to_assets
    let assets = lst_dispatcher.convert_to_assets(shares);
    assert(assets == deposit_amount, 'Asset conversion incorrect');

    // Test convert_to_shares
    let converted_shares = lst_dispatcher.convert_to_shares(deposit_amount);
    assert(converted_shares == shares, 'Share conversion incorrect');

    // Test max_deposit
    let max_deposit = lst_dispatcher.max_deposit(setup.user);
    assert(max_deposit > 0, 'Max deposit should be positive');

    // Test preview_deposit
    let preview_shares = lst_dispatcher.preview_deposit(deposit_amount);
    assert(preview_shares == shares, 'Preview deposit incorrect');

    // Test rebase (this should be called by the liquid staking contract)
    let new_total_assets = deposit_amount + 10_000_000_000_000_000_000; // Add 10 STRK as reward
    cheat_caller_address(setup.lst_address, setup.stake_stark_contact, CheatSpan::TargetCalls(1));
    lst_dispatcher.rebase(new_total_assets);

    let updated_total_assets = lst_dispatcher.total_assets();
    assert(updated_total_assets == new_total_assets, 'Rebase failed');

    // Test shares_per_asset after rebase
    let shares_per_asset = lst_dispatcher.shares_per_asset();
    assert(shares_per_asset < 1_000_000_000_000_000_000, 'Share/asset must - after rebase');
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
    let initial_withdrawal_window_period: u64 = 86400;

    let mut calldata = ArrayTrait::new();
    strk_address.serialize(ref calldata);
    pool_contract.serialize(ref calldata);
    delegator.class_hash.serialize(ref calldata);
    stSTRK.class_hash.serialize(ref calldata);
    initial_platform_fee.serialize(ref calldata);
    platform_fee_recipient.serialize(ref calldata);
    initial_withdrawal_window_period.serialize(ref calldata);
    admin.serialize(ref calldata);

    let (contract_address, _) = contract.deploy(@calldata).unwrap();

    (
        contract_address,
        IStakeStarkDispatcher { contract_address },
        IStakeStarkViewDispatcher { contract_address }
    )
}
