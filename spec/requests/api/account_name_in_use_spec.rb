# frozen_string_literal: true

require 'rails_helper'

# Account names are not unique. New Account and Convert Lead both answer 409
# (account_name_in_use) when the name is taken, listing only the same-name
# accounts the rep can open. Accounts in locations they cannot see are never
# mentioned (not even as a count) and never joined.
RSpec.describe 'Account name in use', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:here) { company.locations.create!(name: 'Denver', timezone: 'UTC') }
  let(:there) { company.locations.create!(name: 'Aurora', timezone: 'UTC') }

  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'Kevin', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:admin) do
    User.create!(email: "admin-#{SecureRandom.hex(3)}@example.com", first_name: 'Ada', last_name: 'Admin',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin', status: 'active')
  end

  def headers_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end

  def json = JSON.parse(response.body)

  # Created first, so it is the lowest id: a name lookup would pick it.
  let!(:hidden) { company.accounts.create!(name: 'SMITH', location_id: there.id, email: 'secret@example.com', billing_city: 'Aurora') }
  let!(:visible) { company.accounts.create!(name: 'Smith', location_id: here.id, email: 'smith.here@example.com', billing_city: 'Denver') }
  let!(:unassigned) { company.accounts.create!(name: 'smith ', location_id: nil) }

  # A location-restricted rep: RBAC on, not an admin, assigned to Denver only.
  def restrict_to_here!
    allow_any_instance_of(ApplicationController).to receive(:authorize_action!).and_return(true)
    allow_any_instance_of(User).to receive(:uses_rbac?).and_return(true)
    allow_any_instance_of(User).to receive(:effective_admin?).and_return(false)
    allow_any_instance_of(PermissionService).to receive(:accessible_location_ids).and_return([here.id])
  end

  describe 'POST /api/v1/accounts (New Account)' do
    it 'asks with 409 listing only the accounts the rep can open, and creates nothing' do
      restrict_to_here!

      expect {
        post '/api/v1/accounts', params: { account: { name: 'Smith' } }.to_json, headers: headers_for(rep)
      }.not_to change(Account, :count)

      expect(response).to have_http_status(:conflict)
      expect(json['code']).to eq('account_name_in_use')
      expect(json['accounts'].map { |a| a['id'] }).to contain_exactly(visible.id, unassigned.id)
      expect(json).not_to have_key('hiddenCount')
      expect(response.body).not_to include('secret@example.com')
      expect(response.body).not_to include('Aurora')
      expect(json['duplicate']).to include('field' => 'name', 'id' => visible.id)
    end

    it 'creates without asking when the only same-name account is hidden' do
      restrict_to_here!
      visible.destroy
      unassigned.destroy

      post '/api/v1/accounts', params: { account: { name: 'Smith' } }.to_json, headers: headers_for(rep)

      expect(response).to have_http_status(:created), response.body
      expect(response.body).not_to include('secret@example.com')
      expect(company.accounts.where('LOWER(TRIM(name)) = ?', 'smith').count).to eq(2)
    end

    it 'lists every same-name account for an admin' do
      post '/api/v1/accounts', params: { account: { name: ' smith' } }.to_json, headers: headers_for(admin)

      expect(response).to have_http_status(:conflict)
      expect(json['accounts'].map { |a| a['id'] }).to eq([hidden.id, visible.id, unassigned.id])
      expect(json).not_to have_key('hiddenCount')
    end

    it 'with allow_duplicate_name creates a second account with the same name' do
      expect {
        post '/api/v1/accounts', params: { account: { name: 'Smith' }, allow_duplicate_name: true }.to_json,
                                 headers: headers_for(admin)
      }.to change(Account, :count).by(1)

      expect(response).to have_http_status(:created), response.body
      expect(company.accounts.where('LOWER(TRIM(name)) = ?', 'smith').count).to eq(4)
    end

    it 'creates without asking when the name is free' do
      post '/api/v1/accounts', params: { account: { name: 'Jones' } }.to_json, headers: headers_for(admin)
      expect(response).to have_http_status(:created), response.body
    end

    it 'check_duplicates does not describe accounts the rep cannot open' do
      restrict_to_here!

      post '/api/v1/accounts/check_duplicates', params: { name: 'Smith' }.to_json, headers: headers_for(rep)

      ids = json['duplicates'].map { |d| d['id'] }
      expect(ids).to contain_exactly(visible.id, unassigned.id)
    end
  end

  describe 'POST /api/crm/leads/:id/convert (Convert Lead)' do
    let(:lead) do
      Lead.create!(company_id: company.id, first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com',
                   status: 'new', location_id: here.id)
    end

    it 'asks with 409 listing only the accounts the rep can open' do
      restrict_to_here!

      post "/api/crm/leads/#{lead.id}/convert", params: { account_name: 'Smith' }.to_json, headers: headers_for(rep)

      expect(response).to have_http_status(:conflict)
      expect(json['accounts'].map { |a| a['id'] }).to contain_exactly(visible.id, unassigned.id)
      expect(json).not_to have_key('hiddenCount')
      expect(response.body).not_to include('secret@example.com')
      expect(lead.reload.is_converted).to be_falsey
    end

    it 'makes a new account without asking when the only same-name account is hidden' do
      restrict_to_here!
      visible.destroy
      unassigned.destroy

      post "/api/crm/leads/#{lead.id}/convert", params: { account_name: 'Smith' }.to_json, headers: headers_for(rep)
      expect(response).to have_http_status(:ok), response.body
      expect(json.dig('account', 'id')).not_to eq(hidden.id)
      expect(hidden.reload.contacts.count).to eq(0)
    end

    it 'will not join a hidden account by id' do
      restrict_to_here!

      post "/api/crm/leads/#{lead.id}/convert",
           params: { account_name: 'Smith', account_mode: 'existing', account_id: hidden.id }.to_json,
           headers: headers_for(rep)

      expect(response).to have_http_status(:not_found)
      expect(lead.reload.is_converted).to be_falsey
    end

    it 'existing without an id joins a visible account, never the hidden one' do
      restrict_to_here!
      post "/api/crm/leads/#{lead.id}/convert", params: { account_name: 'Smith', account_mode: 'existing' }.to_json,
                                                headers: headers_for(rep)

      expect(response).to have_http_status(:ok), response.body
      expect([visible.id, unassigned.id]).to include(json.dig('account', 'id'))
    end

    it 'existing without an id makes a new account when every same-name account is hidden' do
      restrict_to_here!
      visible.destroy
      unassigned.destroy

      post "/api/crm/leads/#{lead.id}/convert", params: { account_name: 'Smith', account_mode: 'existing' }.to_json,
                                                headers: headers_for(rep)

      expect(response).to have_http_status(:ok), response.body
      expect(json.dig('account', 'id')).not_to eq(hidden.id)
      expect(hidden.reload.contacts.count).to eq(0)
    end

    it 'joins a visible account by id' do
      restrict_to_here!

      post "/api/crm/leads/#{lead.id}/convert",
           params: { account_name: 'Smith', account_mode: 'existing', account_id: visible.id }.to_json,
           headers: headers_for(rep)

      expect(response).to have_http_status(:ok), response.body
      expect(json.dig('account', 'id')).to eq(visible.id)
    end
  end
end
