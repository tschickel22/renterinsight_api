# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User, '#accessible_locations' do
  let(:company) { create(:company, use_rbac_system: true) }
  let!(:denver) { company.locations.create!(name: 'Denver') }
  let!(:boise) { company.locations.create!(name: 'Boise') }
  let(:rep_role) { Role.create!(name: 'Rep', key: "rep_#{SecureRandom.hex(3)}", tier: 'location', company_id: company.id) }
  let(:manager_role) { Role.create!(name: 'Boss', key: "boss_#{SecureRandom.hex(3)}", tier: 'company', company_id: company.id) }
  let(:user) { User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P', password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active') }

  def pick(location, active: true)
    UserLocation.create!(user: user, location: location, company_id: company.id, location_role: 'location_staff', active: active)
  end

  def holds(role, tier: 'company')
    UserRoleAssignment.create!(user: user, role: role, company_id: company.id, tier: tier)
  end

  it 'keeps a location role with picked locations to those locations' do
    holds(rep_role)
    pick(denver)
    expect(user.accessible_locations).to contain_exactly(denver)
  end

  it 'ignores a location that was taken away' do
    holds(rep_role)
    pick(denver)
    pick(boise, active: false)
    expect(user.accessible_locations).to contain_exactly(denver)
  end

  it 'gives a location role with nothing picked all locations' do
    holds(rep_role)
    expect(user.accessible_locations).to match_array(company.locations)
  end

  it 'gives a company role all locations even with rows' do
    holds(manager_role)
    pick(denver)
    expect(user.accessible_locations).to match_array(company.locations)
  end
end
