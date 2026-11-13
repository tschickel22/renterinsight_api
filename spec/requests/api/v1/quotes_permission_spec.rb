# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261113091500_add_quotes_resource_to_rbac')

# Quotes used to answer to the 'finance' permission, so a sales rep who could
# build a deal could not open its Quotes tab. They now answer to 'quotes', and
# the migration copies every role's finance grants onto quotes so nobody who
# quoted through finance loses it.
RSpec.describe 'Quotes permission', type: :request do
  let(:company) do
    Company.create!(name: "Quote Perm Co #{SecureRandom.hex(4)}", industry: 'manufactured_housing',
                    use_rbac_system: true)
  end
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }

  before do
    Resource.seed_defaults
    Action.seed_defaults
    Scope.seed_defaults
  end

  def user_with(role)
    user = company.users.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Pat',
                                 last_name: 'Person', password: 'Pass1234!', role: 'user', status: 'active')
    attrs = { role: role, company_id: company.id, tier: role.tier }
    attrs[:location] = location if role.tier == 'location'
    user.user_role_assignments.create!(attrs)
    user
  end

  def headers_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  def role_named(key, tier: 'location')
    Role.create!(company_id: company.id, key: "#{key}-#{SecureRandom.hex(3)}", name: key.titleize, tier: tier, active: true)
  end

  describe 'a sales rep' do
    let(:rep_role) do
      role = role_named('sales_rep')
      Role.send(:grant_sales_rep_permissions!, role)
      role
    end
    let(:rep) { user_with(rep_role) }

    it 'has quotes and no finance' do
      expect(rep_role.has_permission?('quotes', 'create')).to be true
      expect(rep_role.has_permission?('finance', 'read')).to be false
    end

    it 'lists quotes, creates one and opens a deal\'s quotes' do
      buyer = company.contacts.create!(first_name: 'Sam', last_name: 'Smith')
      deal = company.deals.create!(name: 'Smith home', contact_id: buyer.id, location_id: location.id)
      company.quotes.create!(deal_id: deal.id, status: 'draft', location_id: location.id, items: [])

      get '/api/v1/quotes', headers: headers_for(rep)
      expect(response).to have_http_status(:ok)

      post '/api/v1/quotes', params: { quote: { dealId: deal.id, status: 'draft', items: [] } },
                             headers: headers_for(rep), as: :json
      expect(response).to have_http_status(:created)

      get '/api/v1/quotes', params: { deal_id: deal.id }, headers: headers_for(rep)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['quotes'].size).to eq(2)
    end

    it 'still cannot reach payments' do
      get '/api/v1/payments', headers: headers_for(rep)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'a role that quoted through finance before the change' do
    it 'keeps every finance action on quotes after the migration' do
      role = role_named('office_manager', tier: 'company')
      %w[read create update].each { |action| role.grant_permission!('finance', action) }
      quotes = Resource.find_by!(key: 'quotes')
      RolePermission.where(resource: quotes).delete_all

      ActiveRecord::Migration.suppress_messages { AddQuotesResourceToRbac.new.up }

      user = user_with(role)
      get '/api/v1/quotes', headers: headers_for(user)
      expect(response).to have_http_status(:ok)
      post '/api/v1/quotes', params: { quote: { status: 'draft', items: [] } }, headers: headers_for(user), as: :json
      expect(response).to have_http_status(:created)

      expect(role.reload.has_permission?('quotes', 'delete')).to be false
    end

    it 'gives sales_rep roles full quote access' do
      role = Role.create!(company_id: company.id, key: 'sales_rep', name: 'Sales Rep', tier: 'location', active: true)

      ActiveRecord::Migration.suppress_messages { AddQuotesResourceToRbac.new.up }

      %w[create read update delete export].each do |action|
        expect(role.has_permission?('quotes', action)).to be(true), "missing quotes:#{action}"
      end
    end
  end

  it 'turns away a role with neither quotes nor finance' do
    role = role_named('service_tech')
    role.grant_permission!('service', 'read')

    get '/api/v1/quotes', headers: headers_for(user_with(role))
    expect(response).to have_http_status(:forbidden)
  end
end
