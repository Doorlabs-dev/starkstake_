mod components {
    mod access_control;
}
mod contracts {
    mod tests {
        #[cfg(test)]
        mod stake_stark_test;
        #[cfg(test)]
        mod unit_test;

        mod mock {
            mod pool;
            mod staking;
            mod strk;
        }
    }
    mod delegator;
    mod stake_stark;
    mod stSTRK;
}
mod interfaces {
    mod i_delegator;
    mod i_stake_stark;
    mod i_stSTRK;
    mod i_starknet_staking;
}
mod utils {
    mod constants;
}
