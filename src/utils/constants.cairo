// Constants for roles
//use starkstake_::utils::constants::{ADMIN_ROLE, LIQUID_STAKING_ROLE, MINTER_ROLE, PAUSER_ROLE,
//UPGRADER_ROLE, VALIDATOR_ROLE};
//hex(int.from_bytes(Web3.keccak(text="ADMIN_ROLE"), "big") & mask_250)
const ADMIN_ROLE: felt252 = 0x9807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775;
//hex(int.from_bytes(Web3.keccak(text="LIQUID_STAKING_ROLE"), "big") & mask_250)
const LIQUID_STAKING_ROLE: felt252 =
    0x2a603027c9c2ddb20ce7afa61e8d257b3808870d229aff57c91e41f7f0b4814;
//hex(int.from_bytes(Web3.keccak(text="VALIDATOR_ROLE"), "big") & mask_250)
const VALIDATOR_ROLE: felt252 = 0x1702c8af46127c7fa207f89d0b0a8441bb32959a0ac7df790e9ab1a25c98926;
//hex(int.from_bytes(Web3.keccak(text="MINTER_ROLE"), "big") & mask_250)
const MINTER_ROLE: felt252 = 0x32df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6;
//hex(int.from_bytes(Web3.keccak(text="BURNER_ROLE"), "big") & mask_250)
const BURNER_ROLE: felt252 = 0x11d16cbaffd01df69ce1c404f6340ee057498f5f00246190ea54220576a848;
//hex(int.from_bytes(Web3.keccak(text="PAUSER_ROLE"), "big") & mask_250)
const PAUSER_ROLE: felt252 = 0x1d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a;
//hex(int.from_bytes(Web3.keccak(text="UPGRADER_ROLE"), "big") & mask_250)
const UPGRADER_ROLE: felt252 = 0x9ab7a9244df0848122154315af71fe140f3db0fe014031783b0946b8c9d2e3;
//hex(int.from_bytes(Web3.keccak(text="OPERATOR_ROLE"), "big") & mask_250)
const OPERATOR_ROLE: felt252 = 0x3667070c54ef182b0f5858b034beac1b6f3089aa2d3188bb1e8929f4fa9b929;


const ONE_DAY: u64 = 86400; // 1 day in seconds
const WEEK: u64 = ONE_DAY * 7;
