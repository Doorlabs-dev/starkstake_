
use core::array::ArrayTrait;
use core::result::ResultTrait;
use starknet::{
    ContractAddress, ClassHash, get_caller_address, get_block_timestamp, SyscallResultTrait
};
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, ContractClass, cheat_caller_address, CheatSpan
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
const INITIAL_SUPPLY: u256 = 1_000_000_000_000_000_000_000_000; // 1M STRK
const MIN_STAKE: u128 = 10_000_000_000_000_000_000; // 10 STRK
const EXIT_WAIT_WINDOW: u64 = 86400; // 1 day
const PLATFORM_FEE: u16 = 500; // 5%

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
    lst: IstSTRKDispatcher,
    user: ContractAddress,
    admin: ContractAddress,
    fee_recipient: ContractAddress
}

fn setup() -> TestSetup {

    let setup = init_deploy();
    check_deployments(setup);

    setup
}

fn init_deploy() -> TestSetup {
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
    let lst = IstSTRKDispatcher{contract_address: lst_address};
    let fee_recipient = starknet::contract_address_const::<'fee_recipient'>();

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
        lst,
        user,
        admin,
        fee_recipient,
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
    let initial_withdrawal_window_period: u64 = 86400;

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

fn check_deployments(setup: TestSetup) {
    assert(setup.strk.contract_address.is_non_zero(), 'STRK not deployed');
    assert(setup.staking.contract_address.is_non_zero(), 'Staking not deployed');
    assert(setup.pool.contract_address.is_non_zero(), 'Pool not deployed');
    assert(setup.stake_stark.contract_address.is_non_zero(), 'StakeStark not deployed');
    assert(setup.lst_address.is_non_zero(), 'LST not deployed');
}

// Helper functions for common operations
fn approve_and_deposit(
    setup: TestSetup, 
    user: ContractAddress, 
    amount: u256
) -> u256 {
    cheat_caller_address(setup.strk_address, user, CheatSpan::TargetCalls(1));
    setup.strk.approve(setup.stake_stark_contact, amount);

    cheat_caller_address(setup.stake_stark_contact, user, CheatSpan::TargetCalls(1));
    setup.stake_stark.deposit(amount, user, user)
}

fn approve_and_deposit_in_stSTRK(
    setup: TestSetup, 
    user: ContractAddress, 
    amount: u256
) -> u256 {
    cheat_caller_address(setup.strk_address, user, CheatSpan::TargetCalls(1));
    setup.strk.approve(setup.stake_stark_contact, amount);

    cheat_caller_address(setup.lst_address, user, CheatSpan::TargetCalls(1));
    setup.lst.deposit(amount, user)
}

fn request_withdrawal(
    setup: TestSetup, 
    user: ContractAddress, 
    shares: u256
) {
    cheat_caller_address(setup.stake_stark_contact, user, CheatSpan::TargetCalls(1));
    setup.stake_stark.request_withdrawal(shares)
}

fn process_batch(setup: TestSetup){
    cheat_caller_address(setup.stake_stark_contact, setup.admin, CheatSpan::TargetCalls(1));
    setup.stake_stark.process_batch();
}