#[starknet::contract]
mod stSTRK {
    use starknet::{ContractAddress, ClassHash, get_caller_address, get_contract_address};
    use core::num::traits::Bounded;
    use openzeppelin::token::erc20::ERC20Component;
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::security::PausableComponent;
    use openzeppelin::security::ReentrancyGuardComponent;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    use stakestark_::components::access_control::RoleBasedAccessControlComponent;

    use stakestark_::utils::constants::{
        ADMIN_ROLE, MINTER_ROLE, BURNER_ROLE, PAUSER_ROLE, UPGRADER_ROLE
    };

    use stakestark_::interfaces::{
        i_stSTRK::IstSTRK, i_stSTRK::Events, i_stake_stark::IStakeStarkDispatcher,
        i_stake_stark::IStakeStarkDispatcherTrait, i_stake_stark::IStakeStarkViewDispatcher,
        i_stake_stark::IStakeStarkViewDispatcherTrait
    };

    // Component declarations
    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: AccessControlComponent, storage: oz_access_control, event: AccessControlEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent
    );
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    component!(path: RoleBasedAccessControlComponent, storage: access_control, event: RBACEvent);


    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20MetadataImpl = ERC20Component::ERC20MetadataImpl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20CamelOnlyImpl = ERC20Component::ERC20CamelOnlyImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[abi(embed_v0)]
    impl RoleBasedAccessControlImpl =
        RoleBasedAccessControlComponent::RoleBasedAccessControlImpl<ContractState>;
    impl InternalImpl = RoleBasedAccessControlComponent::InternalImpl<ContractState>;

    // Constant
    const INITIAL_SHARES_PER_ASSET: u256 = 1;

    #[storage]
    struct Storage {
        stake_stark: ContractAddress,
        asset: ContractAddress,
        total_assets: u256,
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        oz_access_control: AccessControlComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        access_control: RoleBasedAccessControlComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Events::Deposit,
        Withdraw: Events::Withdraw,
        Rebased: Events::Rebased,
        Redeem: Events::Redeem,
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        RBACEvent: RoleBasedAccessControlComponent::Event,
    }

    /// Initializes the stSTRK contract
    ///
    /// # Arguments
    ///
    /// * `name` - Name of the token
    /// * `symbol` - Symbol of the token
    /// * `stake_stark` - Address of the liquid staking protocol
    /// * `strk_token` - Address of the underlying asset
    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        stake_stark: ContractAddress,
        strk_token: ContractAddress,
    ) {
        self.erc20.initializer(name, symbol);

        self.asset.write(strk_token);
        self.total_assets.write(0);

        self.stake_stark.write(stake_stark);

        // Grant roles
        self.access_control.grant_role(UPGRADER_ROLE, stake_stark);
        self.access_control.grant_role(MINTER_ROLE, stake_stark);
        self.access_control.grant_role(BURNER_ROLE, stake_stark);
    }

    #[abi(embed_v0)]
    impl stSTRKImpl of IstSTRK<ContractState> {
        /// Returns the address of the underlying asset
        fn asset(self: @ContractState) -> ContractAddress {
            self.asset.read()
        }

        /// Returns the total amount of the underlying asset
        fn total_assets(self: @ContractState) -> u256 {
            self.total_assets.read()
        }

        /// Converts a given amount of assets to shares
        ///
        /// # Arguments
        ///
        /// * `assets` - Amount of assets to convert
        ///
        /// # Returns
        ///
        /// The equivalent amount of shares
        fn convert_to_shares(self: @ContractState, assets: u256) -> u256 {
            if self.total_assets() == 0 {
                assets * INITIAL_SHARES_PER_ASSET
            } else {
                (assets * self.erc20.total_supply()) / self.total_assets()
            }
        }

        /// Converts a given amount of shares to assets
        ///
        /// # Arguments
        ///
        /// * `shares` - Amount of shares to convert
        ///
        /// # Returns
        ///
        /// The equivalent amount of assets
        fn convert_to_assets(self: @ContractState, shares: u256) -> u256 {
            if self.erc20.total_supply() == 0 {
                shares / INITIAL_SHARES_PER_ASSET
            } else {
                (shares * self.total_assets()) / self.erc20.total_supply()
            }
        }

        /// Returns the maximum amount of the underlying asset that can be deposited
        ///
        /// # Arguments
        ///
        /// * `receiver` - Address that will receive the minted tokens
        ///
        /// # Returns
        ///
        /// The maximum amount of assets that can be deposited
        fn max_deposit(self: @ContractState, receiver: ContractAddress) -> u256 {
            if self.pausable.is_paused() {
                0
            } else {
                Bounded::<u256>::MAX - self.total_assets()
            }
        }

        /// Simulates the effects of depositing assets at the current status
        ///
        /// # Arguments
        ///
        /// * `assets` - Amount of assets to deposit
        ///
        /// # Returns
        ///
        /// The amount of shares that would be minted
        fn preview_deposit(self: @ContractState, assets: u256) -> u256 {
            self.convert_to_shares(assets)
        }

        /// Deposits assets and mints shares to receiver
        ///
        /// # Arguments
        ///
        /// * `assets` - Amount of assets to deposit
        /// * `receiver` - Address that will receive the minted shares
        ///
        /// # Returns
        ///
        /// The amount of shares minted
        fn deposit(ref self: ContractState, assets: u256, receiver: ContractAddress) -> u256 {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let shares = self.preview_deposit(assets);
            assert(shares != 0, 'ZERO_SHARES');

            let caller = get_caller_address();

            // Call deposit function of StakeStarkProtocol
            let stake_stark = IStakeStarkDispatcher { contract_address: self.stake_stark.read() };
            let minted_shares = stake_stark.deposit(assets, receiver, caller);

            assert(minted_shares == shares, 'Shares mismatch');

            self.emit(Events::Deposit { sender: caller, owner: receiver, assets, shares });

            self.reentrancy_guard.end();
            shares
        }

        /// Returns the maximum amount of shares that can be minted
        ///
        /// # Arguments
        ///
        /// * `receiver` - Address that will receive the minted tokens
        ///
        /// # Returns
        ///
        /// The maximum amount of shares that can be minted
        fn max_mint(self: @ContractState, receiver: ContractAddress) -> u256 {
            if self.pausable.is_paused() {
                0
            } else {
                Bounded::<u256>::MAX - self.erc20.total_supply()
            }
        }

        /// Simulates the effects of minting shares at the current status
        ///
        /// # Arguments
        ///
        /// * `shares` - Amount of shares to mint assets for
        ///
        /// # Returns
        ///
        /// The amount of assets that would be need to mint `share` amount
        fn preview_mint(self: @ContractState, shares: u256) -> u256 {
            if self.erc20.total_supply() == 0 {
                shares / INITIAL_SHARES_PER_ASSET
            } else {
                (shares * self.total_assets()) / self.erc20.total_supply()
            }
        }

        /// Mints exact amount of shares to receiver
        ///
        /// # Arguments
        ///
        /// * `shares` - Amount of shares to mint 
        /// * `receiver` - Address that will receive the minted shares
        ///
        /// # Returns
        ///
        /// The amount of shares minted
        fn mint(ref self: ContractState, shares: u256, receiver: ContractAddress) -> u256 {
            self.access_control.assert_only_role(MINTER_ROLE);
            self.pausable.assert_not_paused();

            let assets = self.preview_mint(shares);
            assert(assets != 0, 'ZERO_ASSETS');

            // Mint shares to receiver
            self.erc20.mint(receiver, shares);

            // Update total assets
            self.total_assets.write(self.total_assets.read() + assets);

            self
                .emit(
                    Events::Deposit {
                        sender: get_caller_address(), owner: receiver, assets, shares
                    }
                );

            shares
        }

        /// Returns the maximum amount of the underlying asset that can be withdrawn
        ///
        /// # Arguments
        ///
        /// * `owner` - Address of the owner
        ///
        /// # Returns
        ///
        /// The maximum amount of assets that can be withdrawn
        fn max_withdraw(self: @ContractState, owner: ContractAddress) -> u256 {
            if self.pausable.is_paused() {
                0
            } else {
                self.convert_to_assets(self.erc20.balance_of(owner))
            }
        }

        /// Simulates the effects of withdrawing assets at the current status
        ///
        /// # Arguments
        ///
        /// * `assets` - Amount of assets to withdraw
        ///
        /// # Returns
        ///
        /// The amount of shares that would be burned
        fn preview_withdraw(self: @ContractState, assets: u256) -> u256 {
            if self.total_assets() == 0 {
                0
            } else {
                (assets * self.erc20.total_supply() + self.total_assets() - 1) / self.total_assets()
            }
        }

        /// Burns shares from owner and sends exactly assets token to receiver
        ///
        /// # Arguments
        ///
        /// * `assets` - Amount of assets to withdraw
        /// * `receiver` - Address that will receive the assets
        /// * `owner` - Address of the owner of the shares
        ///
        /// # Returns
        ///
        /// The amount of shares burned
        fn withdraw(
            ref self: ContractState, assets: u256, receiver: ContractAddress, owner: ContractAddress
        ) -> u256 {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let caller = get_caller_address();
            let shares = self.preview_withdraw(assets);

            if caller != owner {
                let allowed = self.erc20.allowance(owner, caller);
                assert(allowed >= shares, 'EXCEED_ALLOWANCE');
                self.erc20._approve(owner, caller, allowed - shares);
            }

            // Call request_withdrawal function of StakeStarkProtocol
            let stake_stark = IStakeStarkDispatcher { contract_address: self.stake_stark.read() };
            stake_stark.request_withdrawal(shares);

            self.emit(Events::Withdraw { sender: caller, receiver, owner, assets, shares });

            self.reentrancy_guard.end();
            shares
        }

        /// Returns the maximum amount of shares that can be redeemed
        ///
        /// # Arguments
        ///
        /// * `owner` - Address of the owner
        ///
        /// # Returns
        ///
        /// The maximum amount of shares that can be redeemed
        fn max_redeem(self: @ContractState, owner: ContractAddress) -> u256 {
            if self.pausable.is_paused() {
                0
            } else {
                self.erc20.balance_of(owner)
            }
        }

        /// Simulates the effects of redeeming shares at the current status
        ///
        /// # Arguments
        ///
        /// * `shares` - Amount of shares to redeem
        ///
        /// # Returns
        ///
        /// The amount of assets that would be withdrawn
        fn preview_redeem(self: @ContractState, shares: u256) -> u256 {
            self.convert_to_assets(shares)
        }


        /// Burns exact amount of shares from owner and sends assets to receiver
        ///
        /// # Arguments
        ///
        /// * `shares` - Amount of shares to redeem
        /// * `receiver` - Address that will receive the assets
        /// * `owner` - Address of the owner of the shares
        ///
        /// # Returns
        ///
        /// The amount of assets withdrawn
        fn redeem(
            ref self: ContractState, shares: u256, receiver: ContractAddress, owner: ContractAddress
        ) -> u256 {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let caller = get_caller_address();
            if caller != owner {
                let allowed = self.erc20.allowance(owner, caller);
                assert(allowed >= shares, 'EXCEED_ALLOWANCE');
                self.erc20._approve(owner, caller, allowed - shares);
            }

            let assets = self.preview_redeem(shares);

            // Call request_withdrawal function of StakeStarkProtocol
            let stake_stark = IStakeStarkDispatcher { contract_address: self.stake_stark.read() };
            stake_stark.request_withdrawal(shares);

            self.emit(Events::Redeem { caller, receiver, owner, assets, shares });

            self.reentrancy_guard.end();
            assets
        }

        /// Updates the total amount of assets
        ///
        /// # Arguments
        ///
        /// * `new_total_assets` - New total amount of assets
        fn rebase(ref self: ContractState, new_total_assets: u256) {
            self.access_control.assert_only_role(MINTER_ROLE);
            let old_total_assets = self.total_assets.read();
            self.total_assets.write(new_total_assets);

            self.emit(Events::Rebased { old_total_assets, new_total_assets });
        }

        /// Burns shares from a specified address
        ///
        /// # Arguments
        ///
        /// * `share` - Amount of shares to burn
        /// * `caller` - Address from which to burn shares
        fn burn(ref self: ContractState, share: u256, caller: ContractAddress) {
            self.access_control.assert_only_role(MINTER_ROLE);
            let assets_to_burn = self.convert_to_assets(share);
            self.erc20.burn(caller, share);
            self.total_assets.write(self.total_assets.read() - assets_to_burn);
        }

        /// Returns the current ratio of shares to assets
        ///
        /// # Returns
        ///
        /// The number of shares per asset, scaled by 1e18
        fn shares_per_asset(self: @ContractState) -> u256 {
            if self.total_assets() == 0 {
                INITIAL_SHARES_PER_ASSET
            } else {
                (self.erc20.total_supply() * 1_000_000_000_000_000_000) / self.total_assets()
            }
        }

        /// Pauses the contract
        fn pause(ref self: ContractState) {
            self.access_control.assert_only_role(PAUSER_ROLE);
            self.pausable.pause();
        }

        /// Unpauses the contract
        fn unpause(ref self: ContractState) {
            self.access_control.assert_only_role(PAUSER_ROLE);
            self.pausable.unpause();
        }

        /// Upgrades the contract to a new implementation
        ///
        /// # Arguments
        ///
        /// * `new_class_hash` - The class hash of the new implementation
        fn upgrade(ref self: ContractState, new_class_hash: starknet::ClassHash) {
            self.access_control.assert_only_role(UPGRADER_ROLE);
            self.upgradeable.upgrade(new_class_hash);
        }
    }

    impl ERC20HooksImpl of ERC20Component::ERC20HooksTrait<ContractState> {
        fn before_update(
            ref self: ERC20Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {}

        fn after_update(
            ref self: ERC20Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {}
    }
}
