const { RpcProvider, Account, json, Contract, CallData, constants } = require("starknet");
const fs = require("fs");

// Load environment variables
require("dotenv").config();

const LST_PATH = "target/dev/stakestark__stSTRK.contract_class.json";
const LIQUID_STAKING_PATH = "target/dev/stakestark__StakeStark.contract_class.json";
const DELEGATOR_PATH = "target/dev/stakestark__Delegator.contract_class.json";

// Setup provider and account
const provider = new RpcProvider({ nodeUrl: process.env.RPC_URL });
const account = new Account(provider, process.env.ACCOUNT_ADDRESS, process.env.PRIVATE_KEY);

async function main() {
    const lstClassHash = await declareContract(LST_PATH);
    console.log("stSTRK Class Hash:", lstClassHash);

    const liquidStakingClassHash = await declareContract(LIQUID_STAKING_PATH);
    console.log("StakeStark Class Hash:", liquidStakingClassHash);

    const delegatorClassHash = await declareContract(DELEGATOR_PATH);
    console.log("Delegator Class Hash:", delegatorClassHash);

    const liquidStakingAbi = json.parse(fs.readFileSync(LIQUID_STAKING_PATH)).abi;
    const constructorCalldata = CallData.compile({
        strk_token: process.env.STRK_TOKEN_ADDRESS,
        pool_contract: process.env.POOL_CONTRACT_ADDRESS,
        delegator_class_hash: delegatorClassHash,
        initial_delegator_count: 22, // 22 initial delegators
        stSTRK_class_hash: lstClassHash,
        initial_platform_fee: 500, // 5% fee, adjust as needed
        platform_fee_recipient: process.env.PLATFORM_FEE_RECIPIENT,
        initial_withdrawal_window_period: 300, // 5 min for testnet
        admin: process.env.ADMIN_ADDRESS,
        operator: process.env.OPERATOR_ADDRESS
    });

    const deployResponse = await account.deployContract({
        classHash: liquidStakingClassHash,
        constructorCalldata
    });

    await provider.waitForTransaction(deployResponse.transaction_hash);
    console.log("StakeStarkProtocol deployed at:", deployResponse.contract_address);

    const liquidStakingContract = new Contract(liquidStakingAbi, deployResponse.contract_address, provider);

    const lstAddress = await liquidStakingContract.get_lst_address();
    console.log("LST Address:", '0x' + lstAddress.toString(16));

    const delegatorAddresses = await liquidStakingContract.get_delegators_address();
    const delegatorAddressesHex = delegatorAddresses.map(address => '0x' + BigInt(address).toString(16));
    console.log("Delegator Addresses:", delegatorAddressesHex);

    const classHashs = {
        lstClassHash: '0x' + lstClassHash,
        liquidStakingClassHash: '0x' + liquidStakingClassHash,
        delegatorClassHash: '0x' + delegatorClassHash,
    }

    const contractAddresses = {
        stakeStarkAddress: '0x' + deployResponse.contract_address,
        lstAddress: '0x' + BigInt(lstAddress).toString(16),
        delegatorAddresses: delegatorAddressesHex
    }

    const deploymentInfo = {
        classHashs,
        contractAddresses
    };

    fs.writeFileSync('.deployed', JSON.stringify(deploymentInfo, null, 2));
    console.log("Deployment info saved to .deployed file");
}

async function declareContract(path) {
    const compiledContract = json.parse(fs.readFileSync(path).toString("ascii"));

    // Check if the contract is already compiled to CASM
    const casmPath = path.replace('.contract_class.json', '.compiled_contract_class.json');
    const compiledCasm = json.parse(fs.readFileSync(casmPath).toString("ascii"));

    const declareResponse = await account.declareIfNot({
        contract: compiledContract,
        casm: compiledCasm
    });
    if (declareResponse.transaction_hash != '') {
        await provider.waitForTransaction(declareResponse.transaction_hash);
    }
    return declareResponse.class_hash;
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
