use core::array::ArrayTrait;
use core::result::ResultTrait;
use starknet::{ContractAddress, ClassHash, get_caller_address, get_block_timestamp, SyscallResultTrait};
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait, ContractClass, cheat_caller_address, CheatSpan, start_cheat_block_timestamp_global ,stop_cheat_block_timestamp_global, cheat_account_contract_address, start_cheat_caller_address_global,stop_cheat_caller_address_global};
use starknet::class_hash::class_hash_const;
use starknet::testing::{set_caller_address, set_contract_address, set_block_timestamp};

use stake_stark::interfaces::i_liquid_staking::{
    ILiquidStaking, ILiquidStakingDispatcher, ILiquidStakingDispatcherTrait,
    ILiquidStakingView, ILiquidStakingViewDispatcher, ILiquidStakingViewDispatcherTrait,
    FeeStrategy
};
use stake_stark::interfaces::i_ls_token::{
    ILSToken, ILSTokenDispatcher, ILSTokenDispatcherTrait
};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use stake_stark::contracts::tests::mock::staking::{IMockStaking, IMockStakingDispatcher, IMockStakingDispatcherTrait};
use stake_stark::contracts::tests::mock::pool::{IMockPool, IMockPoolDispatcher, IMockPoolDispatcherTrait};
use stake_stark::contracts::tests::mock::strk::{ISTRK, ISTRKDispatcher, ISTRKDispatcherTrait};

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
    liquid_staking_contact: ContractAddress,
    liquid_staking: ILiquidStakingDispatcher,
    liquid_staking_view: ILiquidStakingViewDispatcher,
    lst_address: ContractAddress,
    user: ContractAddress,
    admin: ContractAddress,
}

#[test]
fn test_liquid_staking_system() {
    let setup = deploy_and_setup();
    
    check_deployments(setup);
    test_deposit(setup);
    test_request_withdrawal(setup);
    test_process_batch(setup);
    test_withdraw(setup);
    test_fee_strategy(setup);
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
    let (liquid_staking_contact, liquid_staking, liquid_staking_view) = deploy_liquid_staking(strk_contract, pool_contract);
    let lst_address = liquid_staking_view.get_lst_address();

    // Mint some STRK to the user for testing
    strk.mint(user, (stake_amount * 2).into());
    TestSetup {
        strk,
        strk_address: strk_contract,
        staking,
        pool,
        liquid_staking_contact,
        liquid_staking,
        liquid_staking_view,
        lst_address,
        user,
        admin,
    }
}

fn check_deployments(setup: TestSetup) {
    assert(setup.strk.contract_address.is_non_zero(), 'STRK not deployed');
    assert(setup.staking.contract_address.is_non_zero(), 'Staking not deployed');
    assert(setup.pool.contract_address.is_non_zero(), 'Pool not deployed');
    assert(setup.liquid_staking.contract_address.is_non_zero(), 'LiquidStaking not deployed');
    assert(setup.lst_address.is_non_zero(), 'LST not deployed');
}

fn test_deposit(setup: TestSetup) {
    let deposit_amount: u256 = 50_000_000_000_000_000_000; // 50 STRK

    cheat_caller_address(setup.strk_address, setup.user, CheatSpan::TargetCalls(1));
    setup.strk.approve(setup.liquid_staking.contract_address, deposit_amount);

    cheat_caller_address(setup.liquid_staking_contact, setup.user, CheatSpan::TargetCalls(1));
    let shares = setup.liquid_staking.deposit(deposit_amount);

    assert(shares == IERC20Dispatcher{contract_address: setup.lst_address}.balance_of(setup.user),'share is not correct');
    assert(shares > 0, 'Deposit should return shares');
    
    let pending_deposits = setup.liquid_staking_view.get_pending_deposits();
    assert(pending_deposits == deposit_amount, 'Incorrect pending deposits');
}

fn test_request_withdrawal(setup: TestSetup) {
    let withdrawal_shares: u256 = 25_000_000_000_000_000_000; // 25 STRK worth of shares

    cheat_caller_address(setup.liquid_staking_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.liquid_staking.request_withdrawal(withdrawal_shares);

    let pending_withdrawals = setup.liquid_staking_view.get_pending_withdrawals();
    assert(pending_withdrawals > 0, 'No pending withdrawals');

    let withdrawal_requests = setup.liquid_staking_view.get_all_withdrawal_requests(setup.user);
    assert(withdrawal_requests.len() > 0, 'No withdrawal requests');
}

fn test_process_batch(setup: TestSetup) {
    cheat_caller_address(setup.liquid_staking_contact, setup.admin, CheatSpan::TargetCalls(1));
    setup.liquid_staking.process_batch();

    let pending_deposits = setup.liquid_staking_view.get_pending_deposits();
    let pending_withdrawals = setup.liquid_staking_view.get_pending_withdrawals();
    
    assert(pending_deposits == 0, 'Pending deposits not processed');
    assert(pending_withdrawals == 0, 'Pending withdraw not processed');
}

fn test_withdraw(setup: TestSetup) {
    // Advance time to make withdrawal requests available
    start_cheat_block_timestamp_global(get_block_timestamp() + EXIT_WAIT_WINDOW + 1);
    
    let available_requests = setup.liquid_staking_view.get_available_withdrawal_requests(setup.user);
    assert(available_requests.len() > 0, 'No available withdrawals');

    cheat_caller_address(setup.liquid_staking_contact, setup.user, CheatSpan::TargetCalls(1));
    setup.liquid_staking.withdraw();

    let new_available_requests = setup.liquid_staking_view.get_available_withdrawal_requests(setup.user);
    assert(new_available_requests.len() < available_requests.len(), 'Withdrawal not processed');
    stop_cheat_block_timestamp_global();
}

fn test_fee_strategy(setup: TestSetup) {
    let new_fee = FeeStrategy::Flat(300); // 3% fee
    
    cheat_caller_address(setup.liquid_staking_contact, setup.admin, CheatSpan::TargetCalls(1));
    setup.liquid_staking.set_fee_strategy(new_fee);

    let current_fee = setup.liquid_staking_view.get_fee_strategy();
    assert(current_fee == new_fee, 'Fee strategy not updated');
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
fn deploy_liquid_staking(strk_address: ContractAddress, pool_contract: ContractAddress) -> (ContractAddress, ILiquidStakingDispatcher, ILiquidStakingViewDispatcher) {
    let contract = declare("LiquidStaking").unwrap().contract_class();
    let delegator = declare("Delegator").unwrap().contract_class();
    let ls_token = declare("LSToken").unwrap().contract_class();

    let admin = starknet::contract_address_const::<'admin'>();
    let initial_platform_fee: u16 = 500; // 5%
    let platform_fee_recipient = starknet::contract_address_const::<'fee_recipient'>();
    let initial_withdrawal_window_period: u64 = 86400;

    let mut calldata = ArrayTrait::new();
    strk_address.serialize(ref calldata);
    pool_contract.serialize(ref calldata);
    delegator.class_hash.serialize(ref calldata);
    ls_token.class_hash.serialize(ref calldata);
    initial_platform_fee.serialize(ref calldata);
    platform_fee_recipient.serialize(ref calldata);
    initial_withdrawal_window_period.serialize(ref calldata);
    admin.serialize(ref calldata);

    let (contract_address, _) = contract.deploy(@calldata).unwrap();

    (
        contract_address,
        ILiquidStakingDispatcher { contract_address },
        ILiquidStakingViewDispatcher { contract_address }
    )
}