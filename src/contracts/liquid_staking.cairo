#[starknet::contract]
mod LiquidStaking {
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

    use stake_stark::components::access_control::RoleBasedAccessControlComponent;

    use stake_stark::interfaces::{
        i_liquid_staking::Events, i_liquid_staking::ILiquidStaking,
        i_liquid_staking::ILiquidStakingView, i_liquid_staking::FeeStrategy,
        i_liquid_staking::WithdrawalRequest, i_ls_token::ILSTokenDispatcher,
        i_ls_token::ILSTokenDispatcherTrait, i_delegator::IDelegatorDispatcher,
        i_delegator::IDelegatorDispatcherTrait,
    };

    use stake_stark::utils::constants::{ADMIN_ROLE, ONE_DAY};

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
    const NUM_DELEGATORS: u8 = 22;
    const MAX_FEE_PERCENTAGE: u16 = 1000; // 10%

    #[storage]
    struct Storage {
        ls_token: ContractAddress,
        strk_address: ContractAddress,
        pool_contract: ContractAddress,
        delegators: Map<u8, ContractAddress>,
        delegator_status: Map<u8, (bool, u64)>, // (available_time)
        withdrawal_requests: Map<(ContractAddress, u32), WithdrawalRequest>,
        next_withdrawal_request_id: Map<ContractAddress, u32>,
        delegator_class_hash: ClassHash,
        platform_fee_recipient: ContractAddress,
        min_deposit_amount: u256,
        fee_strategy: FeeStrategy,
        withdrawal_window_period: u64,
        total_pending_deposits: u256,
        total_pending_withdrawals: u256,
        last_processing_time: u64,
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
        WithdrawnMultiple: Events::WithdrawnMultiple,
        RewardDistributed: Events::RewardDistributed,
        DelegatorAdded: Events::DelegatorAdded,
        DelegatorStatusChanged: Events::DelegatorStatusChanged,
        FeeStrategyChanged: Events::FeeStrategyChanged,
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
        ls_token: ContractAddress,
        strk_address: ContractAddress,
        pool_contract: ContractAddress,
        admin: ContractAddress,
        delegator_class_hash: ClassHash,
        initial_platform_fee: u16,
        platform_fee_recipient: ContractAddress,
        initial_withdrawal_window_period: u64,
    ) {
        self._validate_fee_strategy(FeeStrategy::Flat(initial_platform_fee));
        assert(!platform_fee_recipient.is_zero(), 'Invalid fee recipient');

        self.ls_token.write(ls_token);
        self.strk_address.write(strk_address);
        self.pool_contract.write(pool_contract);
        self.delegator_class_hash.write(delegator_class_hash);
        self.fee_strategy.write(FeeStrategy::Flat(initial_platform_fee));
        self.platform_fee_recipient.write(platform_fee_recipient);
        self.withdrawal_window_period.write(initial_withdrawal_window_period);
        self.min_deposit_amount.write(10_000_000_000_000_000_000); // min deposit is 10 STRK

        self.access_control.initialize(admin);

        self._initialize_delegators();

    }

    #[abi(embed_v0)]
    impl LiquidStakingImpl of ILiquidStaking<ContractState> {
        fn deposit(ref self: ContractState, amount: u256) -> u256 {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            assert(amount >= self.min_deposit_amount.read(), 'Deposit amount too low');

            let caller = get_tx_info().account_contract_address;
            let strk_address = IERC20Dispatcher { contract_address: self.strk_address.read() };
            let ls_token = ILSTokenDispatcher { contract_address: self.ls_token.read() };

            // Transfer STRK tokens from caller to this contract
            let transfer_success = strk_address
                .transfer_from(caller, get_contract_address(), amount);
            assert(transfer_success, 'Transfer failed');

            // Mint LS tokens to the user
            let shares = ls_token.mint(amount, caller);
            assert(shares > 0, 'No shares minted');

            self._add_deposit_to_queue(amount);

            self.emit(Events::Deposit { user: caller, amount, shares });

            self.reentrancy_guard.end();
            shares
        }

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

        fn withdraw(ref self: ContractState, request_ids: Array<u32>) {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let (caller, total_assets_to_withdraw) = self._process_withdrawals(request_ids.clone());

            assert(total_assets_to_withdraw > 0, 'No withdrawable requests');

            let strk_token = IERC20Dispatcher { contract_address: self.strk_address.read() };
            strk_token.transfer(caller, total_assets_to_withdraw);

            self
                .emit(
                    Events::WithdrawnMultiple {
                        user: caller,
                        total_assets: total_assets_to_withdraw,
                        processed_request_count: request_ids.len()
                    }
                );

            self.reentrancy_guard.end();
        }

        fn process_batch(ref self: ContractState) {
            self.pausable.assert_not_paused();
            self.access_control.assert_only_role(ADMIN_ROLE);
            self.reentrancy_guard.start();

            self._process_batch();
            self._delegator_withdraw();

            self.reentrancy_guard.end();
        }

        fn collect_and_distribute_rewards(ref self: ContractState) {
            self.pausable.assert_not_paused();
            self.access_control.assert_only_role(ADMIN_ROLE);
            self.reentrancy_guard.start();

            let total_rewards = self._collect_rewards_from_delegators();

            if total_rewards > 0 {
                self._distribute_rewards(total_rewards);
            }

            self.reentrancy_guard.end();
        }

        fn set_fee_strategy(ref self: ContractState, new_strategy: FeeStrategy) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            self._validate_fee_strategy(new_strategy);
            self.fee_strategy.write(new_strategy);
            self.emit(Events::FeeStrategyChanged { new_strategy });
        }

        fn set_platform_fee_recipient(ref self: ContractState, recipient: ContractAddress) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            assert(!recipient.is_zero(), 'Invalid fee recipient');
            self.platform_fee_recipient.write(recipient);
        }

        fn pause(ref self: ContractState) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            self.pausable.pause();
        }

        fn unpause(ref self: ContractState) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            self.pausable.unpause();
        }

        fn process_net_deposit(ref self: ContractState, amount: u256) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            self.reentrancy_guard.start();

            self._delegate_to_available_delegator(amount);

            self.reentrancy_guard.end();
        }

        fn process_net_withdrawal(ref self: ContractState, amount: u256) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            self.reentrancy_guard.start();

            self._request_withdrawal_from_available_delegator(amount);

            self.reentrancy_guard.end();
        }

        fn set_unavailability_period(ref self: ContractState, new_period: u64) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            let old_period = self.withdrawal_window_period.read();
            self.withdrawal_window_period.write(new_period);
            self.emit(Events::UnavailabilityPeriodChanged { old_period, new_period });
        }

        //TODO: add time lock
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            self.upgradeable.upgrade(new_class_hash);
        }

        //TODO: add time lock
        fn upgrade_delegator(ref self: ContractState, new_class_hash: ClassHash) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            self.delegator_class_hash.write(new_class_hash);
            let mut i: u8 = 0;
            while i < NUM_DELEGATORS {
                IDelegatorDispatcher { contract_address: self.delegators.read(i) }
                    .upgrade(new_class_hash);
                i += 1;
            };
        }

        //TODO: add time lock
        fn upgrade_lst(ref self: ContractState, new_class_hash: ClassHash) {
            self.access_control.assert_only_role(ADMIN_ROLE);
            ILSTokenDispatcher { contract_address: self.ls_token.read() }.upgrade(new_class_hash);
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _initialize_delegators(ref self: ContractState) {
            let mut i: u8 = 0;
            while i < NUM_DELEGATORS {
                let delegator_address = self._deploy_delegator();
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

        fn _process_withdrawal_request(
            ref self: ContractState, shares: u256
        ) -> (ContractAddress, u256, u64) {
            let caller = get_tx_info().account_contract_address;
            let ls_token = ILSTokenDispatcher { contract_address: self.ls_token.read() };

            let assets = ls_token.preview_redeem(shares);
            assert(assets > 0, 'Withdrawal amount too small');

            let current_time = get_block_timestamp();
            let withdrawal_time = current_time + self.withdrawal_window_period.read();

            let request_id = self.next_withdrawal_request_id.read(caller);
            self.next_withdrawal_request_id.write(caller, request_id + 1);

            self
                .withdrawal_requests
                .write((caller, request_id), WithdrawalRequest { assets, withdrawal_time });

            ls_token.burn(shares, caller);

            (caller, assets, withdrawal_time)
        }

        fn _process_withdrawals(
            ref self: ContractState, request_ids: Array<u32>
        ) -> (ContractAddress, u256) {
            let caller = get_tx_info().account_contract_address;
            let current_time = get_block_timestamp();
            let mut total_assets_to_withdraw = 0_u256;

            for request_id in request_ids {
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

        fn _add_deposit_to_queue(ref self: ContractState, amount: u256) {
            self.total_pending_deposits.write(self.total_pending_deposits.read() + amount);
            self.emit(Events::DepositAddedInQueue { amount });
        }

        fn _add_withdrawal_to_queue(ref self: ContractState, amount: u256) {
            self.total_pending_withdrawals.write(self.total_pending_withdrawals.read() + amount);
            self.emit(Events::WithdrawalAddedInQueue { amount });
        }

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
                self.process_net_deposit(net_deposit_amount);
            } else if net_withdrawal_amount > 0 {
                self.process_net_withdrawal(net_withdrawal_amount);
            }

            // Reset pending amounts
            self.total_pending_deposits.write(0);
            self.total_pending_withdrawals.write(0);
            self.last_processing_time.write(current_time);

            self
                .emit(
                    Events::BatchProcessed {
                        net_deposit_amount, net_withdrawal_amount, timestamp: current_time
                    }
                );
        }

        fn _delegator_withdraw(ref self: ContractState) {
            let now = get_block_timestamp();
            // 델리게이터 상태 확인 및 출금 처리
            let mut i: u8 = 0;
            while i < NUM_DELEGATORS {
                let (is_available, available_time) = self.delegator_status.read(i);

                // 델리게이터가 사용 불가능하지만 사용 가능 시간이 지난
                // 경우
                if !is_available && now >= available_time {
                    let delegator_address = self.delegators.read(i);
                    let delegator = IDelegatorDispatcher { contract_address: delegator_address, };

                    // 델리게이터의 출금 처리 호출
                    let withdrawn_amount = delegator.process_withdrawal();
                    self
                        .emit(
                            Events::DelegatorWithdrew {
                                id: i, delegator: delegator_address, amount: withdrawn_amount
                            }
                        );

                    // 델리게이터 상태를 다시 사용 가능하도록 업데이트
                    self.delegator_status.write(i, (true, now));
                    self
                        .emit(
                            Events::DelegatorStatusChanged {
                                delegator: delegator_address, status: true, available_time: 0,
                            }
                        );
                }

                i += 1;
            }
        }

        fn _delegate_to_available_delegator(ref self: ContractState, amount: u256) {
            let mut least_stake_index: u8 = 0;
            let mut least_stake: u256 = Bounded::<u256>::MAX;
            let mut found_available = false;

            // 가장 적은 스테이크를 가진 가용 델리게이터 찾기
            let mut i: u8 = 0;
            while i < NUM_DELEGATORS {
                if self._is_delegator_available(i) {
                    let delegator = IDelegatorDispatcher {
                        contract_address: self.delegators.read(i)
                    };
                    let current_stake = delegator.get_total_stake();

                    if current_stake < least_stake {
                        least_stake = current_stake;
                        least_stake_index = i;
                        found_available = true;
                    }
                }
                i += 1;
            };

            // 가용한 델리게이터를 찾지 못한 경우
            assert(found_available, 'No available delegators');

            // 찾은 델리게이터에게 위임
            let delegator = IDelegatorDispatcher {
                contract_address: self.delegators.read(least_stake_index)
            };

            // Transfer STRK directly to the delegator
            let strk_token = IERC20Dispatcher { contract_address: self.strk_address.read() };
            strk_token.transfer(delegator.contract_address, amount);

            delegator.delegate(amount);
        }

        fn _request_withdrawal_from_available_delegator(ref self: ContractState, amount: u256) {
            let mut remaining_amount = amount;

            // First pass: find the best fit delegator
            let mut i: u8 = 0;
            let mut best_fit_index: u8 = 0;
            let mut best_fit_amount: u256 = 0;

            while i < NUM_DELEGATORS {
                if self._is_delegator_available(i) {
                    let delegator = IDelegatorDispatcher {
                        contract_address: self.delegators.read(i)
                    };
                    let delegator_stake = delegator.get_total_stake();

                    if delegator_stake > 0 {
                        if delegator_stake >= remaining_amount
                            && (best_fit_amount == 0 || delegator_stake < best_fit_amount) {
                            best_fit_index = i;
                            best_fit_amount = delegator_stake;
                        } else if best_fit_amount == 0 {
                            best_fit_index = i;
                            best_fit_amount = delegator_stake;
                        }
                    }
                }
                i += 1;
            };

            // Second pass: process withdrawal requests
            i = 0;
            while remaining_amount > 0 && i < NUM_DELEGATORS {
                let current_index = (best_fit_index + i) % NUM_DELEGATORS;
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
                        self
                            .emit(
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

        fn _is_delegator_available(self: @ContractState, index: u8) -> bool {
            let (status, _) = self.delegator_status.read(index);
            status
        }

        // TODO: fix deploy
        fn _deploy_delegator(ref self: ContractState) -> ContractAddress {
            let mut calldata: Array::<felt252> = array![];
            (get_contract_address(), self.pool_contract.read(), self.strk_address.read(), )
                .serialize(ref calldata);

            let (deployed_address, _) = starknet::deploy_syscall(
                self.delegator_class_hash.read(), 0, calldata.span(), false
            )
                .unwrap_syscall();

            self.emit(Events::DelegatorAdded { delegator: deployed_address });

            deployed_address
        }

        fn _process_withdrawal_requests(
            ref self: ContractState, user: ContractAddress, current_time: u64
        ) -> (u256, u32) {
            let mut total_assets_to_withdraw = 0_u256;
            let mut processed_request_count = 0_u32;
            let mut request_id = 0;

            loop {
                let request = self.withdrawal_requests.read((user, request_id));
                if request.assets == 0 {
                    break;
                }
                if current_time >= request.withdrawal_time {
                    total_assets_to_withdraw += request.assets;
                    processed_request_count += 1;
                    // Clear the processed request
                    self
                        .withdrawal_requests
                        .write(
                            (user, request_id), WithdrawalRequest { assets: 0, withdrawal_time: 0 }
                        );
                }
                request_id += 1;
                if request_id >= self.next_withdrawal_request_id.read(user) {
                    break;
                }
            };

            (total_assets_to_withdraw, processed_request_count)
        }

        fn _collect_rewards_from_delegators(ref self: ContractState) -> u256 {
            let mut total_rewards: u256 = 0;
            let mut i: u8 = 0;
            while i < NUM_DELEGATORS {
                let delegator = IDelegatorDispatcher { contract_address: self.delegators.read(i) };
                let delegator_rewards = delegator.collect_rewards();
                total_rewards += delegator_rewards.into();
                i += 1;
            };
            total_rewards
        }

        fn _distribute_rewards(ref self: ContractState, total_rewards: u256) {
            let platform_fee_amount = self._calculate_fee(total_rewards);
            let distributed_reward = total_rewards - platform_fee_amount;

            let strk_address = IERC20Dispatcher { contract_address: self.strk_address.read() };

            // Transfer platform fee
            let fee_recipient = self.platform_fee_recipient.read();
            let transfer_success = strk_address.transfer(fee_recipient, platform_fee_amount);
            assert(transfer_success, 'Platform fee transfer failed');

            // Distribute remaining rewards to LSToken holders
            let ls_token = ILSTokenDispatcher { contract_address: self.ls_token.read() };
            let new_total_assets = ls_token.total_assets() + distributed_reward;
            ls_token.rebase(new_total_assets);

            self
                .emit(
                    Events::RewardDistributed {
                        total_reward: total_rewards, platform_fee_amount, distributed_reward
                    }
                );
        }

        fn _validate_fee_strategy(self: @ContractState, strategy: FeeStrategy) {
            match strategy {
                FeeStrategy::Flat(fee) => {
                    assert(fee <= MAX_FEE_PERCENTAGE, 'Flat fee too high');
                },
                FeeStrategy::Tiered((
                    low_fee, high_fee, threshold
                )) => {
                    assert(low_fee <= MAX_FEE_PERCENTAGE, 'Low fee too high');
                    assert(high_fee <= MAX_FEE_PERCENTAGE, 'High fee too high');
                    assert(low_fee < high_fee, 'Invalid fee tiers');
                    assert(threshold > 0, 'Invalid threshold');
                }
            }
        }

        fn _calculate_fee(self: @ContractState, amount: u256) -> u256 {
            match self.fee_strategy.read() {
                FeeStrategy::Flat(fee) => (amount * fee.into()) / FEE_DENOMINATOR,
                FeeStrategy::Tiered((
                    low_fee, high_fee, threshold
                )) => {
                    if amount <= threshold {
                        (amount * low_fee.into()) / FEE_DENOMINATOR
                    } else {
                        (amount * high_fee.into()) / FEE_DENOMINATOR
                    }
                }
            }
        }
    }

    #[abi(embed_v0)]
    impl LiquidStakingViewImpl of ILiquidStakingView<ContractState> {
        fn get_fee_strategy(self: @ContractState) -> FeeStrategy {
            self.fee_strategy.read()
        }

        fn get_platform_fee_recipient(self: @ContractState) -> ContractAddress {
            self.platform_fee_recipient.read()
        }

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

        fn get_available_withdrawal_requests(
            self: @ContractState, user: ContractAddress
        ) -> Array<(u32, WithdrawalRequest)> {
            let mut available_requests = ArrayTrait::new();
            let current_time = get_block_timestamp();
            let mut request_id = 0;

            loop {
                let request = self.withdrawal_requests.read((user, request_id));
                if request.assets == 0 {
                    break;
                }
                if current_time >= request.withdrawal_time {
                    available_requests.append((request_id, request));
                }
                request_id += 1;
                if request_id >= Bounded::<u32>::MAX {
                    break;
                }
            };

            available_requests
        }

        fn get_unavailability_period(self: @ContractState) -> u64 {
            self.withdrawal_window_period.read()
        }

        fn get_pending_deposits(self: @ContractState) -> u256 {
            self.total_pending_deposits.read()
        }

        fn get_pending_withdrawals(self: @ContractState) -> u256 {
            self.total_pending_withdrawals.read()
        }

        fn get_last_processing_time(self: @ContractState) -> u64 {
            self.last_processing_time.read()
        }
    }
}
