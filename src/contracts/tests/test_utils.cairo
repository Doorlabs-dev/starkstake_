
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

use starkstake_::interfaces::i_stark_stake::{
    IStarkStake, IStarkStakeDispatcher, IStarkStakeDispatcherTrait, IStarkStakeView,
    IStarkStakeViewDispatcher, IStarkStakeViewDispatcherTrait
};
use starkstake_::interfaces::i_stSTRK::{IstSTRK, IstSTRKDispatcher, IstSTRKDispatcherTrait};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use starkstake_::contracts::tests::mock::staking::{
    IMockStaking, IMockStakingDispatcher, IMockStakingDispatcherTrait
};
use starkstake_::contracts::tests::mock::pool::{
    IMockPool, IMockPoolDispatcher, IMockPoolDispatcherTrait
};
use starkstake_::contracts::tests::mock::strk::{ISTRK, ISTRKDispatcher, ISTRKDispatcherTrait};

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
    stark_stake_contact: ContractAddress,
    stark_stake: IStarkStakeDispatcher,
    stark_stake_view: IStarkStakeViewDispatcher,
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
    let (stark_stake_contact, stark_stake, stark_stake_view) = deploy_stark_stake(
        strk_contract, pool_contract
    );
    let lst_address = stark_stake_view.get_lst_address();
    let lst = IstSTRKDispatcher{contract_address: lst_address};
    let fee_recipient = starknet::contract_address_const::<'fee_recipient'>();

    // Mint some STRK to the user for testing
    strk.mint(user, (stake_amount * 2).into());

    TestSetup {
        strk,
        strk_address: strk_contract,
        staking,
        pool,
        stark_stake_contact,
        stark_stake,
        stark_stake_view,
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
fn deploy_stark_stake(
    strk_address: ContractAddress, pool_contract: ContractAddress
) -> (ContractAddress, IStarkStakeDispatcher, IStarkStakeViewDispatcher) {
    let contract = declare("StarkStake").unwrap().contract_class();
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
        IStarkStakeDispatcher { contract_address },
        IStarkStakeViewDispatcher { contract_address }
    )
}

fn check_deployments(setup: TestSetup) {
    assert(setup.strk.contract_address.is_non_zero(), 'STRK not deployed');
    assert(setup.staking.contract_address.is_non_zero(), 'Staking not deployed');
    assert(setup.pool.contract_address.is_non_zero(), 'Pool not deployed');
    assert(setup.stark_stake.contract_address.is_non_zero(), 'StarkStake not deployed');
    assert(setup.lst_address.is_non_zero(), 'LST not deployed');
}

// Helper functions for common operations
fn approve_and_deposit(
    setup: TestSetup, 
    user: ContractAddress, 
    amount: u256
) -> u256 {
    cheat_caller_address(setup.strk_address, user, CheatSpan::TargetCalls(1));
    setup.strk.approve(setup.stark_stake_contact, amount);

    cheat_caller_address(setup.stark_stake_contact, user, CheatSpan::TargetCalls(1));
    setup.stark_stake.deposit(amount, user, user)
}

fn approve_and_deposit_in_stSTRK(
    setup: TestSetup, 
    user: ContractAddress, 
    amount: u256
) -> u256 {
    cheat_caller_address(setup.strk_address, user, CheatSpan::TargetCalls(1));
    setup.strk.approve(setup.stark_stake_contact, amount);

    cheat_caller_address(setup.lst_address, user, CheatSpan::TargetCalls(1));
    setup.lst.deposit(amount, user)
}

fn request_withdrawal(
    setup: TestSetup, 
    user: ContractAddress, 
    shares: u256
) {
    cheat_caller_address(setup.stark_stake_contact, user, CheatSpan::TargetCalls(1));
    setup.stark_stake.request_withdrawal(shares, user)
}

fn process_batch(setup: TestSetup){
    cheat_caller_address(setup.stark_stake_contact, setup.admin, CheatSpan::TargetCalls(1));
    setup.stark_stake.process_batch();
}