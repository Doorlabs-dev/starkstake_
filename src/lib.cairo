mod components {
    mod access_control;
}
mod contracts {
    mod tests {
        #[cfg(test)]
        mod test_utils;
        #[cfg(test)]
        mod stark_stake_test;
        #[cfg(test)]
        mod stSTRK_test;        
        #[cfg(test)]
        mod integration_test;

        mod mock {
            mod pool;
            mod staking;
            mod strk;
        }
    }
    mod delegator;
    mod stark_stake;
    mod staked_strk_token;
}
mod interfaces {
    mod i_delegator;
    mod i_stark_stake;
    mod i_starknet_staking;
    mod i_staked_strk_token;
}
mod utils {
    mod constants;
}
