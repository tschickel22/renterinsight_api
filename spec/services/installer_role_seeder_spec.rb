# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261103130000_seed_project_access_and_installer_role')

RSpec.describe InstallerRoleSeeder do
  before do
    { 'projects' => 'Projects', 'calendar' => 'Calendar', 'accounting' => 'Accounting', 'users' => 'Users' }.each do |key, name|
      Resource.find_or_create_by!(key: key) { |r| r.name = name }
    end
    Scope.find_or_create_by!(key: 'all') { |s| s.name = 'All' }
  end

  let(:installer_co) { create(:company, name: 'Install Co', industry: 'installer') }

  def granted?(role, resource, action)
    role.role_permissions.joins(:resource, :action).where(granted: true, resources: { key: resource }, actions: { key: action }).exists?
  end

  it 'gives a new install company its own Installer role' do
    role = Role.find_by!(company_id: installer_co.id, key: 'installer')

    expect(role.name).to eq('Installer')
    expect(role.is_system_role).to be(false)
    expect(granted?(role, 'projects', 'update')).to be(true)
    expect(granted?(role, 'projects', 'view_pii')).to be(true)
    expect(granted?(role, 'calendar', 'read')).to be(true)
    expect(granted?(role, 'projects', 'delete')).to be(false)
    expect(granted?(role, 'accounting', 'read')).to be(false)
    expect(granted?(role, 'users', 'read')).to be(false)
  end

  it 'gives no such role to any other company' do
    company = create(:company, name: 'Dealer Co', industry: 'manufactured_housing')

    expect(Role.where(company_id: company.id, key: 'installer')).to be_empty
  end

  it 'seeds a company that becomes an installer later' do
    company = create(:company, name: 'Dealer Co', industry: 'manufactured_housing')

    company.update!(industry: 'installer')

    expect(Role.where(company_id: company.id, key: 'installer').count).to eq(1)
  end

  it "leaves an installer's edits alone when run again" do
    role = Role.find_by!(company_id: installer_co.id, key: 'installer')
    role.role_permissions.delete_all

    described_class.call(installer_co)

    expect(role.reload.role_permissions.count).to eq(0)
    expect(Role.where(company_id: installer_co.id, key: 'installer').count).to eq(1)
  end

  it 'shows the role only to its own company' do
    other = create(:company, name: 'Dealer Co', industry: 'manufactured_housing')
    role = Role.find_by!(company_id: installer_co.id, key: 'installer')
    person = User.create!(email: 'x@dealer.example', first_name: 'X', last_name: 'Y', password: 'Pass1234!',
                          company_id: other.id, role: 'staff', status: 'active')

    expect(person.assign_rbac_role(role.key, company_id: other.id)).to be_nil
  end

  describe 'the migration' do
    def migrate = ActiveRecord::Migration.suppress_messages { SeedProjectAccessAndInstallerRole.new.up }

    let!(:staff) { Role.find_or_create_by!(company_id: nil, tier: 'company', key: 'company_staff') { |r| r.name = 'Company Staff'; r.is_system_role = true } }
    let!(:read_only) { Role.find_or_create_by!(company_id: nil, tier: 'company', key: 'company_read_only') { |r| r.name = 'Read-Only User'; r.is_system_role = true } }
    let!(:dealers_own) { Role.create!(company_id: create(:company, name: 'Dealer Co').id, tier: 'company', key: 'own_role', name: 'Own Role') }

    it 'gives built-in roles projects, Read-Only read only, and leaves company roles alone' do
      migrate

      expect(granted?(staff, 'projects', 'read')).to be(true)
      expect(granted?(staff, 'projects', 'update')).to be(true)
      expect(granted?(read_only, 'projects', 'read')).to be(true)
      expect(granted?(read_only, 'projects', 'update')).to be(false)
      expect(dealers_own.role_permissions.count).to eq(0)
    end

    it 'can run twice, and seeds install companies that already exist' do
      company = create(:company, name: 'Old Install', industry: 'manufactured_housing')
      company.update_column(:industry, 'installer')

      2.times { migrate }

      expect(Role.where(company_id: company.id, key: 'installer').count).to eq(1)
    end
  end
end
