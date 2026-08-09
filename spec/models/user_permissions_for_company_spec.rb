# frozen_string_literal: true

require 'rails_helper'

# #permissions_for_company feeds the frontend's navigation filter (sidebar
# items, tabs, buttons). It is deliberately NOT the authorization gate, which
# stays in #has_permission?. The distinction matters: a '*:*:*' entry tells the
# frontend to skip the permission matrix entirely, so anything that returns the
# wildcard can never be given a narrowed menu.
RSpec.describe User, '#permissions_for_company', type: :model do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing',
                    use_rbac_system: true)
  end

  before do
    Resource.seed_defaults
    Action.seed_defaults
    Scope.seed_defaults
  end

  def build_user(role:)
    company.users.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T',
                          last_name: 'U', password: 'Pass1234!', role: role)
  end

  def assign(user, role_record, tier: 'company', location: nil)
    user.user_role_assignments.create!(role: role_record, company_id: company.id, tier: tier,
                                       location: location)
  end

  describe 'platform-tier users' do
    it 'keeps the wildcard for a platform admin' do
      user = build_user(role: 'platform_admin')
      expect(user.permissions_for_company(company.id)).to eq(['*:*:*'])
    end
  end

  describe 'when RBAC is disabled for the company' do
    it 'keeps the wildcard so legacy tenants are unaffected' do
      company.update!(use_rbac_system: false)
      user = build_user(role: 'user')
      expect(user.permissions_for_company(company.id)).to eq(['*:*:*'])
    end
  end

  describe 'a company admin holding an RBAC role' do
    let(:admin) { build_user(role: 'user') }
    let(:admin_role) do
      Role.create!(company_id: company.id, key: 'company_admin', name: 'Company Admin',
                   tier: 'company', active: true)
    end

    before do
      Role.grant_full_permissions!(admin_role)
      assign(admin, admin_role)
    end

    it 'expands the real grants instead of returning the wildcard' do
      perms = admin.permissions_for_company(company.id)

      expect(perms).not_to include('*:*:*')
      expect(perms).to include('inventory:read:all')
      expect(perms.size).to be > 100
    end

    it 'still covers every resource, so the menu is unchanged for a full admin' do
      perms = admin.permissions_for_company(company.id)
      resources = perms.map { |p| p.split(':').first }.uniq

      expect(resources).to match_array(Resource.active.pluck(:key))
    end

    # The whole point of the change: revoking a resource has to reach the menu.
    it 'drops a resource from the list once its grants are revoked' do
      marketing = Resource.find_by!(key: 'campaigns')
      RolePermission.where(role: admin_role, resource: marketing).update_all(granted: false)
      admin.instance_variable_set(:@rbac_permissions_cache, nil)

      perms = admin.permissions_for_company(company.id)

      expect(perms.map { |p| p.split(':').first }).not_to include('campaigns')
      expect(perms.map { |p| p.split(':').first }).to include('inventory')
    end

    # Hiding is not denying. Authorization stays permissive for admins so this
    # change cannot lock anyone out of an endpoint they could reach before.
    it 'does not narrow authorization' do
      RolePermission.where(role: admin_role, resource: Resource.find_by!(key: 'campaigns'))
                    .update_all(granted: false)
      admin.instance_variable_set(:@rbac_permissions_cache, nil)

      expect(admin.has_permission?('campaigns', 'read', 'all', company.id)).to be true
    end
  end

  describe 'a legacy admin with no RBAC assignment' do
    # role column says company_admin but nothing was ever assigned, so there are
    # no grants to expand. Falling through to an empty list would blank their
    # navigation entirely.
    it 'keeps the wildcard rather than returning an empty list' do
      legacy = build_user(role: 'company_admin')

      expect(legacy.user_role_assignments).to be_empty
      expect(legacy.permissions_for_company(company.id)).to eq(['*:*:*'])
    end
  end

  describe 'a non-admin with a narrow role' do
    it 'returns only the granted resources' do
      rep = build_user(role: 'user')
      rep_role = Role.create!(company_id: company.id, key: "rep-#{SecureRandom.hex(3)}",
                              name: 'Rep', tier: 'location', active: true)
      Role.grant_deal_desk!(rep_role, %w[read])
      loc = company.locations.create!(name: 'Showroom', timezone: 'America/Denver')
      assign(rep, rep_role, tier: 'location', location: loc)

      perms = rep.permissions_for_company(company.id)

      expect(perms).to eq(['deal_desk:read:all'])
    end

    it 'returns an empty list when no role is assigned' do
      orphan = build_user(role: 'user')
      expect(orphan.permissions_for_company(company.id)).to eq([])
    end
  end
end
