#[starknet::contract]
mod LSToken {
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, get_contract_address
    };
    use core::num::traits::Bounded;
    use openzeppelin::token::erc20::ERC20Component;
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::security::PausableComponent;
    use openzeppelin::security::ReentrancyGuardComponent;
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    use stake_stark::components::access_control::RoleBasedAccessControlComponent;

    use stake_stark::utils::constants::{ADMIN_ROLE, MINTER_ROLE, PAUSER_ROLE, UPGRADER_ROLE};

    // Component declarations
    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: AccessControlComponent, storage: oz_access_control, event: AccessControlEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent);
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
    impl RoleBasedAccessControlImpl = RoleBasedAccessControlComponent::RoleBasedAccessControlImpl<ContractState>;
    impl InternalImpl = RoleBasedAccessControlComponent::InternalImpl<ContractState>;

    // Constant
    const INITIAL_SHARES_PER_ASSET: u256 = 1_000_000_000_000_000_000; // 1e18

    #[storage]
    struct Storage {
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
        Deposit: Deposit,
        Withdraw: Withdraw,
        Rebased: Rebased,
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

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        #[key]
        sender: ContractAddress,
        #[key]
        owner: ContractAddress,
        assets: u256,
        shares: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Withdraw {
        #[key]
        sender: ContractAddress,
        #[key]
        receiver: ContractAddress,
        #[key]
        owner: ContractAddress,
        assets: u256,
        shares: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Rebased{
        old_total_assets: u256,
        new_total_assets: u256
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        asset: ContractAddress,
        admin: ContractAddress,
    ) {
        self.erc20.initializer(name, symbol);

        self.asset.write(asset);
        self.total_assets.write(0);
    }

    #[generate_trait]
    impl LSTokenImpl of ILSToken {
        fn asset(self: @ContractState) -> ContractAddress {
            self.asset.read()
        }

        fn total_assets(self: @ContractState) -> u256 {
            self.total_assets.read()
        }

        fn convert_to_shares(self: @ContractState, assets: u256) -> u256 {
            if self.total_assets() == 0 {
                assets * INITIAL_SHARES_PER_ASSET
            } else {
                (assets * self.erc20.total_supply()) / self.total_assets()
            } 
        }

        fn convert_to_assets(self: @ContractState, shares: u256) -> u256 {
            if self.erc20.total_supply() == 0 {
                shares / INITIAL_SHARES_PER_ASSET
            } else {
                (shares * self.total_assets()) / self.erc20.total_supply()
            }
        }

        fn max_deposit(self: @ContractState, receiver: ContractAddress) -> u256 {
            if self.pausable.is_paused() {
                0
            } else {
                Bounded::<u256>::MAX - self.total_assets()
            }
        }

        fn preview_deposit(self: @ContractState, assets: u256) -> u256 {
            self.convert_to_shares(assets)
        }

        fn deposit(ref self: ContractState, assets: u256, receiver: ContractAddress) -> u256 {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let shares = self.preview_deposit(assets);
            assert(shares != 0, 'ZERO_SHARES');

            let caller = get_caller_address();
            let asset_token = IERC20Dispatcher { contract_address: self.asset.read() };
            
            // Transfer assets from caller to this contract
            asset_token.transfer_from(caller, get_contract_address(), assets);

            // Mint shares to receiver
            self.erc20.mint(receiver, shares);

            // Update total assets
            self.total_assets.write(self.total_assets.read() + assets);

            self.emit(Deposit { sender: caller, owner: receiver, assets, shares });

            self.reentrancy_guard.end();
            shares
        }

        fn max_mint(self: @ContractState, receiver: ContractAddress) -> u256 {
            if self.pausable.is_paused() {
                0
            } else {
                Bounded::<u256>::MAX - self.erc20.total_supply()
            }
        }

        fn preview_mint(self: @ContractState, assets: u256) -> u256 {
            if self.erc20.total_supply() == 0 {
                assets * INITIAL_SHARES_PER_ASSET
            } else {
                (assets * self.erc20.total_supply() + self.total_assets() - 1) / self.total_assets()
            }
        }        

        fn mint(ref self: ContractState, assets: u256, receiver: ContractAddress) -> u256 {
            self.access_control.assert_only_role(MINTER_ROLE);
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();
        
            let shares = self.preview_mint(assets);
            assert(shares != 0, 'ZERO_SHARES');
        
            // Mint shares to receiver
            self.erc20.mint(receiver, shares);
        
            // Update total assets
            self.total_assets.write(self.total_assets.read() + assets);
        
            self.emit(Deposit { sender: get_caller_address(), owner: receiver, assets, shares });
        
            self.reentrancy_guard.end();
            shares
        }

        fn max_withdraw(self: @ContractState, owner: ContractAddress) -> u256 {
            if self.pausable.is_paused() {
                0
            } else {
                self.convert_to_assets(self.erc20.balance_of(owner))
            }
        }

        fn preview_withdraw(self: @ContractState, assets: u256) -> u256 {
            if self.total_assets() == 0 {
                0
            } else {
                (assets * self.erc20.total_supply() + self.total_assets() - 1) / self.total_assets()
            }
        }

        fn withdraw(
            ref self: ContractState, 
            assets: u256, 
            receiver: ContractAddress, 
            owner: ContractAddress
        ) -> u256 {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let shares = self.preview_withdraw(assets);
            assert(shares != 0, 'ZERO_SHARES');

            let caller = get_caller_address();
            if caller != owner {
                let allowed = self.erc20.allowance(owner, caller);
                assert(allowed >= shares, 'EXCEED_ALLOWANCE');
                self.erc20._approve(owner, caller, allowed - shares);
            }

            self.erc20.burn(owner, shares);

            let asset_token = IERC20Dispatcher { contract_address: self.asset.read() };
            asset_token.transfer(receiver, assets);

            self.total_assets.write(self.total_assets.read() - assets);

            self.emit(Withdraw { sender: caller, receiver, owner, assets, shares });

            self.reentrancy_guard.end();
            shares
        }

        fn max_redeem(self: @ContractState, owner: ContractAddress) -> u256 {
            if self.pausable.is_paused() {
                0
            } else {
                self.erc20.balance_of(owner)
            }
        }

        fn preview_redeem(self: @ContractState, shares: u256) -> u256 {
            self.convert_to_assets(shares)
        }

        fn redeem(
            ref self: ContractState, 
            shares: u256, 
            receiver: ContractAddress, 
            owner: ContractAddress
        ) -> u256 {
            self.pausable.assert_not_paused();
            self.reentrancy_guard.start();

            let assets = self.preview_redeem(shares);
            assert(assets != 0, 'ZERO_ASSETS');

            let caller = get_caller_address();
            if caller != owner {
                let allowed = self.erc20.allowance(owner, caller);
                assert(allowed >= shares, 'EXCEED_ALLOWANCE');
                self.erc20._approve(owner, caller, allowed - shares);
            }

            self.erc20.burn(owner, shares);

            let asset_token = IERC20Dispatcher { contract_address: self.asset.read() };
            asset_token.transfer(receiver, assets);

            self.total_assets.write(self.total_assets.read() - assets);

            self.emit(Withdraw { sender: caller, receiver, owner, assets, shares });

            self.reentrancy_guard.end();
            assets
        }

        fn rebase(ref self: ContractState, new_total_assets: u256) {
            self.access_control.assert_only_role(MINTER_ROLE);
            let old_total_assets = self.total_assets.read();
            self.total_assets.write(new_total_assets);

            self.emit(Rebased { old_total_assets, new_total_assets });
        }

        fn burn(ref self: ContractState, share: u256, caller: ContractAddress) {
            self.access_control.assert_only_role(MINTER_ROLE);
            self.erc20.burn(caller, share);
            let assets_to_burn = self.convert_to_assets(share);
            self.total_assets.write(self.total_assets.read() - assets_to_burn);
        }

        fn shares_per_asset(self: @ContractState) -> u256 {
            if self.total_assets() == 0 {
                INITIAL_SHARES_PER_ASSET
            } else {
                (self.erc20.total_supply() * 1_000_000_000_000_000_000) / self.total_assets()
            }
        }
    }

    #[generate_trait]
    impl UpgradeableFunctions of UpgradeableFunctionsTrait {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
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