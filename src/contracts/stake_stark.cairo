#[starknet::contract]
mod StakeStark {
    use core::num::traits::Bounded;
    use core::array::ArrayTrait;
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_block_timestamp, get_contract_address,
        SyscallResultTrait, syscalls::deploy_syscall, get_tx_info
    };
    use starknet::storage::Map;

    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::security::PausableComponent;
    use openzeppelin::security::ReentrancyGuardComponent;
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    use stakestark_::components::access_control::RoleBasedAccessControlComponent;

    use stakestark_::interfaces::{
        i_stake_stark::Events, i_stake_stark::IStakeStark, i_stake_stark::IStakeStarkView,
        i_stake_stark::WithdrawalRequest, i_stSTRK::IstSTRKDispatcher,
        i_stSTRK::IstSTRKDispatcherTrait, i_delegator::IDelegatorDispatcher,
        i_delegator::IDelegatorDispatcherTrait,
    };

    use stakestark_::utils::constants::{
        ADMIN_ROLE, ONE_DAY, OPERATOR_ROLE, PAUSER_ROLE, UPGRADER_ROLE
    };

    // Component declarations
    component!(path: AccessControlComponent, storage: oz_access_control, event: AccessControlEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent
    );
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: RoleBasedAccessControlComponent, storage: access_control, event: RBACEvent);

    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl RoleBasedAccessControlImpl =
        RoleBasedAccessControlComponent::RoleBasedAccessControlImpl<ContractState>;
    impl InternalImpl = RoleBasedAccessControlComponent::InternalImpl<ContractState>;

    // Constants
    const FEE_DENOMINATOR: u256 = 10000;
    const MAX_FEE_PERCENTAGE: u16 = 1000; // 10%

    #[storage]
    struct Storage {
        stSTRK: ContractAddress,
        strk_token: ContractAddress,
        pool_contract: ContractAddress,
        num_delegators: u8,
        delegators: Map<u8, ContractAddress>,
        delegator_status: Map<u8, (bool, u64)>, // (available_time)
        withdrawal_requests: Map<(ContractAddress, u32), WithdrawalRequest>,
        next_withdrawal_request_id: Map<ContractAddress, u32>,
        delegator_class_hash: ClassHash,
        platform_fee_recipient: ContractAddress,
        min_deposit_amount: u256,
        fee_ratio: u16,
        withdrawal_window_period: u64,
        total_pending_deposits: u256,
        total_pending_withdrawals: u256,
        #[substorage(v0)]
        oz_access_control: AccessControlComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        access_control: RoleBasedAccessControlComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Events::Deposit,
        DelegatorWithdrew: Events::DelegatorWithdrew,
        WithdrawalRequested: Events::WithdrawalRequested,
        Withdraw: Events::Withdraw,
        RewardDistributed: Events::RewardDistributed,
        StSRTKDeployed: Events::StSRTKDeployed,
        DelegatorAdded: Events::DelegatorAdded,
        DelegatorStatusChanged: Events::DelegatorStatusChanged,
        FeeRatioChanged: Events::FeeRatioChanged,
        DepositAddedInQueue: Events::DepositAddedInQueue,
        WithdrawalAddedInQueue: Events::WithdrawalAddedInQueue,
        BatchProcessed: Events::BatchProcessed,
        UnavailabilityPeriodChanged: Events::UnavailabilityPeriodChanged,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        RBACEvent: RoleBasedAccessControlComponent::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        strk_token: ContractAddress,
        pool_contract: ContractAddress,
        delegator_class_hash: ClassHash,
        initial_delegator_count: u8,
        stSTRK_class_hash: ClassHash,
        initial_platform_fee: u16,
        platform_fee_recipient: ContractAddress,
        initial_withdrawal_window_period: u64,
        admin: ContractAddress,
        operator: ContractAddress,
    ) {
        assert(initial_platform_fee <= MAX_FEE_PERCENTAGE, 'fee ratio too high');
        assert(!platform_fee_recipient.is_zero(), 'Invalid fee recipient');

        self.strk_token.write(strk_token);
        self.pool_contract.write(pool_contract);
        self.delegator_class_hash.write(delegator_class_hash);
        self.num_delegators.write(initial_delegator_count);
        self.stSTRK.write(self._deploy_lst(stSTRK_class_hash));
        self.fee_ratio.write(initial_platform_fee);
        self.platform_fee_recipient.write(platform_fee_recipient);
        self.withdrawal_window_period.write(initial_withdrawal_window_period);
        self.min_deposit_amount.write(10_000_000_000_000_000_000); // min deposit is 10 STRK

        self.access_control.initialize(admin);
        self.access_control.grant_role(OPERATOR_ROLE, operator);
        self._initialize_delegators();
    }

    #[abi(embed_v0)]
    impl StakeStarkImpl of IStakeStark<ContractState> {
        /// Deposits STRK tokens and mints corresponding LS tokens.
        ///
        /// # Arguments
        ///
        /// * `assets` - The amount of STRK tokens to deposit
        /// * `receiver` - Address that will receive the minted shares
        /// * `user` - Address of user who call deposit in stSTRK contract
        ///
        /// # Returns
        ///
        /// The number of LS tokens minted
        fn deposit(ref self: ContractState, assets: u256, receiver: ContractAddress, user: ContractAddress) -> u256 {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            assert(assets >= self.min_deposit_amount.read(), 'Deposit amount too low');

            let mut caller: ContractAddress = get_caller_address();
            //set user to caller when caller is stSTRK
            if caller == self.get_lst_address(){
                caller = user
            }

            let strk_dispatcher = IERC20Dispatcher { contract_address: self.strk_token.read() };
            let stSTRK = IstSTRKDispatcher { contract_address: self.stSTRK.read() };

            // Transfer STRK tokens from caller to this contract
            assert(
                strk_dispatcher.transfer_from(caller, get_contract_address(), assets),
                'Transfer failed'
            );

            // Mint LS tokens to the user
            let shares = if receiver.is_zero() {
                stSTRK.mint(stSTRK.preview_deposit(assets), caller)
            } else {
                stSTRK.mint(stSTRK.preview_deposit(assets), receiver)
            };

            assert(shares > 0, 'No shares minted');

            self._add_deposit_to_queue(assets);

            self.emit(Events::Deposit { user: caller, amount: assets, shares });

            self.reentrancy_guard.end();
            shares
        }

        /// Requests a withdrawal of LS tokens.
        ///
        /// # Arguments
        ///
        /// * `shares` - The amount of LS tokens to withdraw
        fn request_withdrawal(ref self: ContractState, shares: u256) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let (caller, assets, withdrawal_time) = self._process_withdrawal_request(shares);

            self._add_withdrawal_to_queue(assets);

            self
                .emit(
                    Events::WithdrawalRequested {
                        user: caller,
                        request_id: self.next_withdrawal_request_id.read(caller) - 1,
                        shares,
                        assets,
                        withdrawal_time
                    }
                );

            self.reentrancy_guard.end();
        }

        /// Processes available withdrawal requests for the caller.
        fn withdraw(ref self: ContractState) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let (caller, total_assets_to_withdraw) = self._process_withdrawals();

            assert(total_assets_to_withdraw > 0, 'No withdrawable requests');

            let strk_token = IERC20Dispatcher { contract_address: self.strk_token.read() };
            strk_token.transfer(caller, total_assets_to_withdraw);

            self.emit(Events::Withdraw { user: caller, total_assets: total_assets_to_withdraw });

            self.reentrancy_guard.end();
        }

        /// Processes pending deposits and withdrawals, and collects rewards.
        /// Can only be called by an account with the OPERATOR_ROLE.
        fn process_batch(ref self: ContractState) {
            self.pausable.assert_not_paused();
            self.access_control.assert_only_role(OPERATOR_ROLE);
            self.reentrancy_guard.start();

            self._delegator_withdraw();
            self._process_batch();

            let total_rewards = self._collect_rewards_from_delegators();

            if total_rewards > 0 {
                self._distribute_rewards(total_rewards);
            }

            self.reentrancy_guard.end();
        }

        /// Sets a new fee ratio for the protocol.
        /// Can only be called by an account with the ADMIN_ROLE.
        ///
        /// # Arguments
        ///
        /// * `new_ratio` - The new fee ratio to set
        fn set_fee_ratio(ref self: ContractState, new_ratio: u16) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            assert(new_ratio <= MAX_FEE_PERCENTAGE, 'Fee ratio too high');

            self.fee_ratio.write(new_ratio);
            self.emit(Events::FeeRatioChanged { new_ratio });
        }

        /// Sets a new recipient for the platform fees.
        /// Can only be called by an account with the ADMIN_ROLE.
        ///
        /// # Arguments
        ///
        /// * `recipient` - The address of the new fee recipient
        fn set_platform_fee_recipient(ref self: ContractState, recipient: ContractAddress) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            assert(!recipient.is_zero(), 'Invalid fee recipient');
            self.platform_fee_recipient.write(recipient);
        }

        /// Pauses the contract.
        /// Can only be called by an account with the PAUSER_ROLE.
        fn pause(ref self: ContractState) {
            self.access_control.assert_only_role(PAUSER_ROLE);
            self.pausable.pause();
        }

        /// Unpauses the contract.
        /// Can only be called by an account with the PAUSER_ROLE
        fn unpause(ref self: ContractState) {
            self.access_control.assert_only_role(PAUSER_ROLE);
            self.pausable.unpause();
        }

        /// Pauses the contract.
        /// Can only be called by an account with the PAUSER_ROLE.
        fn pause_stSTRK(ref self: ContractState) {
            self.access_control.assert_only_role(PAUSER_ROLE);
            IstSTRKDispatcher{contract_address: self.get_lst_address()}.pause();
        }

        /// Unpauses the contract.
        /// Can only be called by an account with the PAUSER_ROLE
        fn unpause_stSTRK(ref self: ContractState) {
            self.access_control.assert_only_role(PAUSER_ROLE);
            IstSTRKDispatcher{contract_address: self.get_lst_address()}.unpause();
        }
        
        /// Pauses the contract.
        /// Can only be called by an account with the PAUSER_ROLE.
        fn pause_delegator(ref self: ContractState) {
            self.access_control.assert_only_role(PAUSER_ROLE);
            let mut i: u8 = 0;
            while i < self.num_delegators.read() {
                IDelegatorDispatcher { contract_address: self.delegators.read(i) }.pause();
                i += 1;
            };
        }

        /// Unpauses the contract.
        /// Can only be called by an account with the PAUSER_ROLE
        fn unpause_delegator(ref self: ContractState) {
            self.access_control.assert_only_role(PAUSER_ROLE);
            let mut i: u8 = 0;
            while i < self.num_delegators.read() {
                IDelegatorDispatcher { contract_address: self.delegators.read(i) }.unpause();
                i += 1;
            };
        }

        /// Pauses the contract.
        /// Can only be called by an account with the PAUSER_ROLE.
        fn pause_all(ref self: ContractState) {
            self.access_control.assert_only_role(PAUSER_ROLE);
            self.pause();
            self.pause_stSTRK();
            self.pause_delegator();
        }

        /// Unpauses the contract.
        /// Can only be called by an account with the PAUSER_ROLE
        fn unpause_all(ref self: ContractState) {
            self.access_control.assert_only_role(PAUSER_ROLE);
            self.unpause();
            self.unpause_stSTRK();
            self.unpause_delegator();
        }

        /// Sets a new unavailability period for withdrawals.
        /// Can only be called by an account with the ADMIN_ROLE.
        ///
        /// # Arguments
        ///
        /// * `new_period` - The new unavailability period in seconds
        fn set_unavailability_period(ref self: ContractState, new_period: u64) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            let old_period = self.withdrawal_window_period.read();
            self.withdrawal_window_period.write(new_period);
            self.emit(Events::UnavailabilityPeriodChanged { old_period, new_period });
        }

        /// Upgrades the contract to a new implementation.
        /// Can only be called by an account with the UPGRADER_ROLE.
        ///
        /// # Arguments
        ///
        /// * `new_class_hash` - The class hash of the new implementation
        //TODO: add time lock
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.access_control.assert_only_role(UPGRADER_ROLE);
            self.upgradeable.upgrade(new_class_hash);
        }

        //TODO: add time lock
        fn upgrade_delegator(ref self: ContractState, new_class_hash: ClassHash) {
            self.access_control.assert_only_role(UPGRADER_ROLE);
            self.delegator_class_hash.write(new_class_hash);
            let mut i: u8 = 0;
            while i < self.num_delegators.read() {
                IDelegatorDispatcher { contract_address: self.delegators.read(i) }
                    .upgrade(new_class_hash);
                i += 1;
            };
        }

        //TODO: add time lock
        fn upgrade_lst(ref self: ContractState, new_class_hash: ClassHash) {
            self.access_control.assert_only_role(UPGRADER_ROLE);
            IstSTRKDispatcher { contract_address: self.stSTRK.read() }.upgrade(new_class_hash);
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        /// Initializes delegators for the contract.
        ///
        /// This function is called during the contract constructor.
        fn _initialize_delegators(ref self: ContractState) {
            let mut i: u8 = 0;
            while i < self.num_delegators.read() {
                let delegator_address = self._deploy_delegator(i);
                self.delegators.write(i, delegator_address);
                self.delegator_status.write(i, (true, get_block_timestamp()));
                self
                    .emit(
                        Events::DelegatorStatusChanged {
                            delegator: delegator_address,
                            status: true,
                            available_time: get_block_timestamp()
                        }
                    );
                i += 1;
            };
        }

        /// Processes a withdrawal request for LS tokens.
        ///
        /// # Arguments
        ///
        /// * `shares` - The amount of LS tokens to withdraw
        ///
        /// # Returns
        ///
        /// A tuple containing the caller's address, the amount of assets to withdraw, and the
        /// withdrawal time.
        ///
        /// This function is called by `request_withdrawal`.
        fn _process_withdrawal_request(
            ref self: ContractState, shares: u256
        ) -> (ContractAddress, u256, u64) {
            let caller = get_tx_info().account_contract_address;
            let stSTRK = IstSTRKDispatcher { contract_address: self.stSTRK.read() };

            let assets = stSTRK.preview_redeem(shares);
            assert(assets > 0, 'Withdrawal amount too small');

            let current_time = get_block_timestamp();
            let withdrawal_time = current_time + self.withdrawal_window_period.read();

            let request_id = self.next_withdrawal_request_id.read(caller);
            self.next_withdrawal_request_id.write(caller, request_id + 1);

            self
                .withdrawal_requests
                .write((caller, request_id), WithdrawalRequest { assets, withdrawal_time });

            stSTRK.burn(shares, caller);

            (caller, assets, withdrawal_time)
        }

        /// Processes all available withdrawal requests for a user.
        ///
        /// # Returns
        ///
        /// A tuple containing the caller's address and the total amount of assets to withdraw.
        ///
        /// This function is called by `withdraw`.
        fn _process_withdrawals(ref self: ContractState) -> (ContractAddress, u256) {
            let caller = get_tx_info().account_contract_address;
            let current_time = get_block_timestamp();
            let mut total_assets_to_withdraw: u256 = 0;

            let requests = self.get_available_withdrawal_requests(caller);

            for (
                request_id, _
            ) in requests {
                let request = self.withdrawal_requests.read((caller, request_id));
                assert(request.assets > 0, 'Invalid request ID');
                assert(current_time >= request.withdrawal_time, 'Request not ready');

                total_assets_to_withdraw += request.assets;

                // Clear the processed request
                self
                    .withdrawal_requests
                    .write(
                        (caller, request_id), WithdrawalRequest { assets: 0, withdrawal_time: 0 }
                    );
            };

            (caller, total_assets_to_withdraw)
        }


        /// Adds a deposit to the pending queue.
        ///
        /// # Arguments
        ///
        /// * `amount` - The amount of tokens to add to the pending deposits
        ///
        /// This function is called by `deposit`.
        fn _add_deposit_to_queue(ref self: ContractState, amount: u256) {
            self.total_pending_deposits.write(self.total_pending_deposits.read() + amount);
            self.emit(Events::DepositAddedInQueue { amount });
        }

        /// Adds a withdrawal to the pending queue.
        ///
        /// # Arguments
        ///
        /// * `amount` - The amount of tokens to add to the pending withdrawals
        ///
        /// This function is called by `request_withdrawal`.
        fn _add_withdrawal_to_queue(ref self: ContractState, amount: u256) {
            self.total_pending_withdrawals.write(self.total_pending_withdrawals.read() + amount);
            self.emit(Events::WithdrawalAddedInQueue { amount });
        }

        /// Processes pending deposits and withdrawals.
        ///
        /// This function is called by `process_batch`.
        fn _process_batch(ref self: ContractState) {
            let current_time = get_block_timestamp();
            //assert(current_time >= self.last_processing_time.read() + ONE_DAY, 'Too early');

            let deposits = self.total_pending_deposits.read();
            let withdrawals = self.total_pending_withdrawals.read();

            let (net_deposit_amount, net_withdrawal_amount) = if deposits > withdrawals {
                (deposits - withdrawals, 0)
            } else {
                (0, withdrawals - deposits)
            };

            if net_deposit_amount > 0 {
                self._delegate_to_available_delegator(net_deposit_amount);
            } else if net_withdrawal_amount > 0 {
                self._request_withdrawal_from_available_delegator(net_withdrawal_amount);
            }

            // Reset pending amounts
            self.total_pending_deposits.write(0);
            self.total_pending_withdrawals.write(0);

            self
                .emit(
                    Events::BatchProcessed {
                        net_deposit_amount, net_withdrawal_amount, timestamp: current_time
                    }
                );
        }

        /// Processes withdrawals for all delegators.
        ///
        /// This function is called by `process_batch`.
        fn _delegator_withdraw(ref self: ContractState) {
            let now = get_block_timestamp();

            let mut i: u8 = 0;
            while i < self.num_delegators.read() {
                let (is_available, available_time) = self.delegator_status.read(i);

                // If the delegator is unavailable but the available time has passed
                if !is_available && now >= available_time {
                    let delegator_address = self.delegators.read(i);
                    let delegator = IDelegatorDispatcher { contract_address: delegator_address };

                    // Call the delegator's withdrawal process
                    let withdrawn_amount = delegator.process_withdrawal();
                    self
                        .emit(
                            Events::DelegatorWithdrew {
                                id: i, delegator: delegator_address, amount: withdrawn_amount
                            }
                        );

                    // Update the delegator status to available again
                    self.delegator_status.write(i, (true, now));
                    self
                        .emit(
                            Events::DelegatorStatusChanged {
                                delegator: delegator_address, status: true, available_time: now,
                            }
                        );
                }

                i += 1;
            }
        }

        /// Delegates tokens to the available delegator with the least stake.
        ///
        /// # Arguments
        ///
        /// * `amount` - The amount of tokens to delegate
        ///
        /// This function is called by `_process_batch`.
        fn _delegate_to_available_delegator(ref self: ContractState, amount: u256) {
            let mut least_stake_index: u8 = 0;
            let mut least_stake: u256 = Bounded::<u256>::MAX;
            let mut found_available = false;

            // Find the available delegator with the least stake
            let mut i: u8 = 0;
            while i < self.num_delegators.read() {
                if self._is_delegator_available(i) {
                    let delegator = IDelegatorDispatcher {
                        contract_address: self.delegators.read(i)
                    };
                    let current_stake = delegator.get_total_stake();

                    if current_stake == 0 {
                        least_stake_index = i;
                        found_available = true;
                        break;
                    } else if current_stake < least_stake {
                        least_stake = current_stake;
                        least_stake_index = i;
                        found_available = true;
                    }
                }
                i += 1;
            };

            // If no available delegator is found
            assert(found_available, 'No available delegators');

            // Delegate to the found delegator
            let delegator = IDelegatorDispatcher {
                contract_address: self.delegators.read(least_stake_index)
            };

            // Transfer STRK directly to the delegator
            let strk_token = IERC20Dispatcher { contract_address: self.strk_token.read() };
            strk_token.transfer(delegator.contract_address, amount);

            delegator.delegate(amount);
        }

        /// Requests withdrawals from available delegators to fulfill the given amount.
        ///
        /// # Arguments
        ///
        /// * `amount` - The total amount of tokens to withdraw
        ///
        /// This function is called by `_process_batch`.
        fn _request_withdrawal_from_available_delegator(ref self: ContractState, amount: u256) {
            let mut remaining_amount = amount;
        
            // First pass: find the best fit delegator
            let mut i: u8 = 0;
            let mut best_fit_index: u8 = 0;
            let mut best_fit_amount: u256 = 0;
            let mut largest_available_amount: u256 = 0;
            let mut largest_amount_index: u8 = 0;
        
            while i < self.num_delegators.read() {
                if self._is_delegator_available(i) {
                    let delegator = IDelegatorDispatcher {
                        contract_address: self.delegators.read(i)
                    };
        
                    let delegator_stake = delegator.get_total_stake();
        
                    if delegator_stake > 0 {
                        // Track the largest stake in case we need to fall back to it
                        if delegator_stake > largest_available_amount {
                            largest_available_amount = delegator_stake;
                            largest_amount_index = i;
                        }
        
                        // Update best fit if this delegator can fulfill the request with less excess
                        if delegator_stake >= remaining_amount 
                            && (best_fit_amount == 0 || delegator_stake < best_fit_amount) {
                            best_fit_index = i;
                            best_fit_amount = delegator_stake;
                        }
                    }
                }
                i += 1;
            };
        
            // If no exact fit was found, use the delegator with largest stake
            if best_fit_amount == 0 {
                best_fit_index = largest_amount_index;
                best_fit_amount = largest_available_amount;
            }
        
            // Second pass: process withdrawal requests
            i = 0;
            while remaining_amount > 0 && i < self.num_delegators.read() {
                let current_index = (best_fit_index + i) % self.num_delegators.read();
                if self._is_delegator_available(current_index) {
                    let delegator = IDelegatorDispatcher {
                        contract_address: self.delegators.read(current_index)
                    };
                    let delegator_stake = delegator.get_total_stake();
        
                    if delegator_stake > 0 {
                        let withdrawal_amount = if delegator_stake <= remaining_amount {
                            delegator_stake
                        } else {
                            remaining_amount
                        };
        
                        delegator.request_withdrawal(withdrawal_amount);
                        remaining_amount -= withdrawal_amount;
        
                        // Update status after withdrawal request
                        let current_time = get_block_timestamp();
                        let unavailable_until = current_time + self.withdrawal_window_period.read();
                        self.delegator_status.write(current_index, (false, unavailable_until));
                        self.emit(
                            Events::DelegatorStatusChanged {
                                delegator: self.delegators.read(current_index),
                                status: false,
                                available_time: unavailable_until
                            }
                        );
                    }
                }
                i += 1;
            };
        
            assert(remaining_amount == 0, 'Insufficient available funds');
        }

        /// Checks if a delegator is available.
        ///
        /// # Arguments
        ///
        /// * `index` - The index of the delegator to check
        ///
        /// # Returns
        ///
        /// `true` if the delegator is available, `false` otherwise.
        ///
        /// This function is called by `_delegate_to_available_delegator` and
        /// `_request_withdrawal_from_available_delegator`.
        fn _is_delegator_available(self: @ContractState, index: u8) -> bool {
            let (status, _) = self.delegator_status.read(index);
            status
        }

        /// Deploys a new delegator contract.
        ///
        /// # Arguments
        ///
        /// * `i` - The index of the delegator
        ///
        /// # Returns
        ///
        /// The address of the deployed delegator contract.
        ///
        /// This function is called by `_initialize_delegators`.
        fn _deploy_delegator(ref self: ContractState, i: u8) -> ContractAddress {
            let mut calldata: Array::<felt252> = array![];
            get_contract_address().serialize(ref calldata);
            self.pool_contract.read().serialize(ref calldata);
            self.strk_token.read().serialize(ref calldata);

            let (deployed_address, _) = starknet::deploy_syscall(
                self.delegator_class_hash.read(),
                get_block_timestamp().into() + i.into(),
                calldata.span(),
                false
            )
                .unwrap_syscall();

            self.emit(Events::DelegatorAdded { delegator: deployed_address });

            deployed_address
        }

        /// Deploys the LST (Liquid Staking Token) contract.
        ///
        /// # Arguments
        ///
        /// * `lst_class_hash` - The class hash of the LST contract
        ///
        /// # Returns
        ///
        /// The address of the deployed LST contract.
        ///
        /// This function is called during the contract constructor.
        fn _deploy_lst(ref self: ContractState, lst_class_hash: ClassHash) -> ContractAddress {
            let mut calldata: Array::<felt252> = array![];
            let name: ByteArray = "staked STRK";
            let symbol: ByteArray = "stSTRK";
            name.serialize(ref calldata);
            symbol.serialize(ref calldata);
            get_contract_address().serialize(ref calldata);
            self.strk_token.read().serialize(ref calldata);

            let (deployed_address, _) = starknet::deploy_syscall(
                lst_class_hash, 0, calldata.span(), false
            )
                .unwrap_syscall();

            self.emit(Events::StSRTKDeployed { address: deployed_address });

            deployed_address
        }

        /// Collects rewards from all delegators.
        ///
        /// # Returns
        ///
        /// The total amount of rewards collected.
        ///
        /// This function is called by `process_batch`.
        fn _collect_rewards_from_delegators(ref self: ContractState) -> u256 {
            let mut total_rewards: u256 = 0;
            let mut i: u8 = 0;
            while i < self.num_delegators.read() {
                let delegator = IDelegatorDispatcher { contract_address: self.delegators.read(i) };
                let delegator_rewards = delegator.collect_rewards();
                total_rewards += delegator_rewards.into();
                i += 1;
            };
            total_rewards
        }


        /// Distributes collected rewards between the platform and LST holders.
        ///
        /// # Arguments
        ///
        /// * `total_rewards` - The total amount of rewards to distribute
        ///
        /// This function is called by `process_batch`.
        fn _distribute_rewards(ref self: ContractState, total_rewards: u256) {
            let platform_fee_amount = self._calculate_fee(total_rewards);
            let distributed_reward = total_rewards - platform_fee_amount;

            let strk_token = IERC20Dispatcher { contract_address: self.strk_token.read() };

            // Transfer platform fee
            let fee_recipient = self.platform_fee_recipient.read();
            let transfer_success = strk_token.transfer(fee_recipient, platform_fee_amount);
            assert(transfer_success, 'Platform fee transfer failed');

            // Distribute remaining rewards to stSTRK holders
            let stSTRK = IstSTRKDispatcher { contract_address: self.stSTRK.read() };
            let new_total_assets = stSTRK.total_assets() + distributed_reward;
            stSTRK.rebase(new_total_assets);

            self
                .emit(
                    Events::RewardDistributed {
                        total_reward: total_rewards, platform_fee_amount, distributed_reward
                    }
                );
        }

        /// Calculates the fee amount based on the current fee ratio.
        ///
        /// # Arguments
        ///
        /// * `amount` - The amount to calculate the fee for
        ///
        /// # Returns
        ///
        /// The calculated fee amount.
        ///
        /// This function is called by `_distribute_rewards`.
        fn _calculate_fee(self: @ContractState, amount: u256) -> u256 {
            amount * self.fee_ratio.read().into() / FEE_DENOMINATOR
        }
    }

    #[abi(embed_v0)]
    impl StakeStarkViewImpl of IStakeStarkView<ContractState> {
        /// Returns the address of the Liquid Staking Token (LST) contract.
        ///
        /// # Returns
        ///
        /// The ContractAddress of the LST contract.
        fn get_lst_address(self: @ContractState) -> ContractAddress {
            self.stSTRK.read()
        }

        /// Returns an array of all delegator addresses.
        ///
        /// # Returns
        ///
        /// An Array of ContractAddress representing all delegators.
        fn get_delegators_address(self: @ContractState) -> Array<ContractAddress> {
            let mut delegators = ArrayTrait::new();
            let mut i = 0;
            while i < self.num_delegators.read() {
                delegators.append(self.delegators.read(i));
                i += 1;
            };
            delegators
        }

        /// Returns the current fee ratio of the contract.
        ///
        /// # Returns
        ///
        /// The current Feeratio.
        fn get_fee_ratio(self: @ContractState) -> u16 {
            self.fee_ratio.read()
        }

        /// Returns the address of the current platform fee recipient.
        ///
        /// # Returns
        ///
        /// The ContractAddress of the platform fee recipient.
        fn get_platform_fee_recipient(self: @ContractState) -> ContractAddress {
            self.platform_fee_recipient.read()
        }


        /// Calculates the total withdrawable amount for a given user.
        ///
        /// # Arguments
        ///
        /// * `user` - The address of the user to check
        ///
        /// # Returns
        ///
        /// The total withdrawable amount as a u256.
        fn get_withdrawable_amount(self: @ContractState, user: ContractAddress) -> u256 {
            let current_time = get_block_timestamp();
            let mut total_withdrawable = 0_u256;
            let mut request_id = 0;

            loop {
                let request = self.withdrawal_requests.read((user, request_id));
                if request.assets == 0 {
                    break;
                }
                if current_time >= request.withdrawal_time {
                    total_withdrawable += request.assets;
                }
                request_id += 1;
                if request_id >= Bounded::<u32>::MAX {
                    break;
                }
            };

            total_withdrawable
        }

        /// Retrieves all withdrawal requests for a given user.
        ///
        /// # Arguments
        ///
        /// * `user` - The address of the user to check
        ///
        /// # Returns
        ///
        /// An Array of WithdrawalRequest structs.
        fn get_all_withdrawal_requests(
            self: @ContractState, user: ContractAddress
        ) -> Array<WithdrawalRequest> {
            let mut requests = ArrayTrait::new();
            let mut request_id = 0;

            loop {
                let request = self.withdrawal_requests.read((user, request_id));
                if request.assets == 0 {
                    break;
                }
                requests.append(request);
                request_id += 1;
                if request_id >= Bounded::<u32>::MAX {
                    break;
                }
            };

            requests
        }

        /// Retrieves all available (ready to be withdrawn) withdrawal requests for a given user.
        ///
        /// # Arguments
        ///
        /// * `user` - The address of the user to check
        ///
        /// # Returns
        ///
        /// An Array of tuples, each containing a request ID (u32) and a WithdrawalRequest struct.
        fn get_available_withdrawal_requests(
            self: @ContractState, user: ContractAddress
        ) -> Array<(u32, WithdrawalRequest)> {
            let mut available_requests = ArrayTrait::new();
            let current_time = get_block_timestamp();
            let next_withdrawal_request_id = self.next_withdrawal_request_id.read(user);

            let mut request_id = if next_withdrawal_request_id > 0 {
                next_withdrawal_request_id - 1
            } else {
                return available_requests;
            };

            loop {
                let request = self.withdrawal_requests.read((user, request_id));
                if request.assets == 0 {
                    break;
                }
                if current_time >= request.withdrawal_time {
                    available_requests.append((request_id, request));
                }
                if request_id == 0 {
                    break;
                }
                request_id -= 1;
            };

            available_requests
        }

        /// Returns the current unavailability period for withdrawals.
        ///
        /// # Returns
        ///
        /// The unavailability period in seconds as a u64.
        fn get_unavailability_period(self: @ContractState) -> u64 {
            self.withdrawal_window_period.read()
        }

        /// Returns the total amount of pending deposits.
        ///
        /// # Returns
        ///
        /// The total pending deposits as a u256.
        fn get_pending_deposits(self: @ContractState) -> u256 {
            self.total_pending_deposits.read()
        }

        /// Returns the total amount of pending withdrawals.
        ///
        /// # Returns
        ///
        /// The total pending withdrawals as a u256.
        fn get_pending_withdrawals(self: @ContractState) -> u256 {
            self.total_pending_withdrawals.read()
        }
    }
}
