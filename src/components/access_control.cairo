use starknet::ContractAddress;

#[starknet::interface]
trait IRoleBasedAccessControl<TContractState> {
    fn has_role(self: @TContractState, role: felt252, account: ContractAddress) -> bool;
    fn get_role_admin(self: @TContractState, role: felt252) -> felt252;
    fn grant_role(ref self: TContractState, role: felt252, account: ContractAddress);
    fn revoke_role(ref self: TContractState, role: felt252, account: ContractAddress);
    fn renounce_role(ref self: TContractState, role: felt252, account: ContractAddress);
}


#[starknet::component]
mod RoleBasedAccessControlComponent {
    use super::ContractAddress;
    use starknet::get_caller_address;
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::access::accesscontrol::AccessControlComponent::AccessControlImpl;
    use openzeppelin::access::accesscontrol::AccessControlComponent::InternalTrait as AccessInternalTrait;
    use openzeppelin_introspection::src5::SRC5Component;

    use starkstake_::utils::constants::{
        ADMIN_ROLE, LIQUID_STAKING_ROLE, MINTER_ROLE, PAUSER_ROLE, UPGRADER_ROLE, VALIDATOR_ROLE, OPERATOR_ROLE
    };

    #[storage]
    struct Storage {}

    #[embeddable_as(RoleBasedAccessControlImpl)]
    impl RoleBasedAccessControl<
        TContractState,
        +HasComponent<TContractState>,
        +Drop<TContractState>,
        impl Access: AccessControlComponent::HasComponent<TContractState>,
        +SRC5Component::HasComponent<TContractState>
    > of super::IRoleBasedAccessControl<ComponentState<TContractState>> {
        fn has_role(
            self: @ComponentState<TContractState>, role: felt252, account: ContractAddress
        ) -> bool {
            get_dep_component!(self, Access).has_role(role, account)
        }

        fn get_role_admin(self: @ComponentState<TContractState>, role: felt252) -> felt252 {
            get_dep_component!(self, Access).get_role_admin(role)
        }

        fn grant_role(
            ref self: ComponentState<TContractState>, role: felt252, account: ContractAddress
        ) {
            let mut access_comp = get_dep_component_mut!(ref self, Access);
            access_comp._grant_role(role, account)
        }

        fn revoke_role(
            ref self: ComponentState<TContractState>, role: felt252, account: ContractAddress
        ) {
            let mut access_comp = get_dep_component_mut!(ref self, Access);
            access_comp.revoke_role(role, account)
        }

        fn renounce_role(
            ref self: ComponentState<TContractState>, role: felt252, account: ContractAddress
        ) {
            let mut access_comp = get_dep_component_mut!(ref self, Access);
            access_comp.renounce_role(role, account)
        }
    }

    #[generate_trait]
    impl InternalImpl<
        TContractState,
        +HasComponent<TContractState>,
        +Drop<TContractState>,
        impl Access: AccessControlComponent::HasComponent<TContractState>,
        +SRC5Component::HasComponent<TContractState>
    > of InternalTrait<TContractState> {
        fn initialize(ref self: ComponentState<TContractState>, admin: ContractAddress) {
            let mut access_comp = get_dep_component_mut!(ref self, Access);
            access_comp.initializer();
            let un_initialized = access_comp.get_role_admin(role: ADMIN_ROLE).is_zero();
            assert(un_initialized, 'Already initialized');

            access_comp._grant_role(ADMIN_ROLE, admin);
            access_comp._grant_role(LIQUID_STAKING_ROLE, admin);
            access_comp._grant_role(MINTER_ROLE, admin);
            access_comp._grant_role(PAUSER_ROLE, admin);
            access_comp._grant_role(UPGRADER_ROLE, admin);
            access_comp._grant_role(OPERATOR_ROLE, admin);

            access_comp.set_role_admin(ADMIN_ROLE, ADMIN_ROLE);
            access_comp.set_role_admin(LIQUID_STAKING_ROLE, ADMIN_ROLE);
            access_comp.set_role_admin(MINTER_ROLE, ADMIN_ROLE);
            access_comp.set_role_admin(PAUSER_ROLE, ADMIN_ROLE);
            access_comp.set_role_admin(UPGRADER_ROLE, ADMIN_ROLE);
            access_comp.set_role_admin(OPERATOR_ROLE, ADMIN_ROLE);
        }

        fn assert_only_role(self: @ComponentState<TContractState>, role: felt252) {
            assert(
                get_dep_component!(self, Access).has_role(role, get_caller_address()),
                'Unauthorized'
            );
        }

        fn assert_only_admin(self: @ComponentState<TContractState>) {
            self.assert_only_role(ADMIN_ROLE);
        }

        fn assert_only_stark_stake(self: @ComponentState<TContractState>) {
            self.assert_only_role(LIQUID_STAKING_ROLE);
        }

        fn assert_only_validator(self: @ComponentState<TContractState>) {
            self.assert_only_role(VALIDATOR_ROLE);
        }

        fn assert_only_minter(self: @ComponentState<TContractState>) {
            self.assert_only_role(MINTER_ROLE);
        }

        fn assert_only_pauser(self: @ComponentState<TContractState>) {
            self.assert_only_role(PAUSER_ROLE);
        }

        fn assert_only_upgrader(self: @ComponentState<TContractState>) {
            self.assert_only_role(UPGRADER_ROLE);
        }

        fn assert_only_operator(self: @ComponentState<TContractState>) {
            self.assert_only_role(OPERATOR_ROLE);
        }
    }
}
