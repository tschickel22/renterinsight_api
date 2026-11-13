# frozen_string_literal: true

require 'rails_helper'

# Regression coverage for two lead->account conversion bugs:
#   1. A lead activity with a NULL description aborted the whole conversion
#      (account_activities.description was NOT NULL while lead_activities allows
#      null). Conversion must now succeed and migrate the activity.
#   2. Converting a lead into a PRE-EXISTING account (matched by name) must
#      backfill the account's missing phone/email/address from the lead.
# Plus: a name already in use is a question (409) until the rep picks join
# ('existing') or a separate account ('new'); two families can share a name.
RSpec.describe 'Api::Crm::Leads conversion', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com",
      first_name: 'T', last_name: 'U',
      password: 'Pass1234!', company_id: company.id,
      role: 'platform_admin'
    )
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let(:lead) do
    Lead.create!(
      company_id: company.id,
      first_name: 'Dorothy', last_name: 'Hughes',
      email: 'dhughes@example.com', phone: '(574) 555-5004',
      street: '123 Main St', city: 'Auburn', state: 'IN', zip: '46706', country: 'USA',
      status: 'new'
    )
  end

  describe 'POST /api/crm/leads/:id/convert with a null-description activity' do
    before do
      # The activity that used to blow up the conversion: a non-text type
      # (meeting) with no description.
      LeadActivity.create!(
        lead_id: lead.id, user_id: user.id,
        activity_type: 'meeting', subject: 'Custom upgrade options review',
        description: nil, status: 'pending', priority: 'medium',
        start_time: Time.current, end_time: Time.current + 1.hour
      )
    end

    it 'converts successfully and migrates the activity instead of failing' do
      post "/api/crm/leads/#{lead.id}/convert",
           params: { account_name: 'Dorothy Hughes' }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      account = Account.find_by(name: 'Dorothy Hughes', company_id: company.id)
      expect(account).to be_present

      migrated = AccountActivity.where(account_id: account.id, activity_type: 'meeting')
      expect(migrated.count).to eq(1)
      # Null description fell back to the subject rather than violating NOT NULL.
      expect(migrated.first.description).to eq('Custom upgrade options review')

      expect(lead.reload.is_converted).to be(true)
    end
  end

  describe 'POST /api/crm/leads/:id/convert into a pre-existing account' do
    let!(:existing_account) do
      # Imported account: has an address but no phone/email yet.
      Account.create!(
        company_id: company.id, name: 'Dorothy Hughes', status: 'active',
        billing_street: '999 Old Rd', billing_city: 'Auburn', billing_state: 'IN'
      )
    end

    it 'asks first: 409 with the account in use, and converts nothing' do
      Contact.create!(company_id: company.id, account_id: existing_account.id, first_name: 'Earl', last_name: 'Hughes')

      expect {
        post "/api/crm/leads/#{lead.id}/convert",
             params: { account_name: ' dorothy hughes ' }.to_json,
             headers: auth_headers
      }.not_to change(Account, :count)

      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body['code']).to eq('account_name_in_use')
      expect(body['existingAccount']).to include('id' => existing_account.id, 'name' => 'Dorothy Hughes', 'contactsCount' => 1)
      expect(body['accounts'].map { |a| a['id'] }).to eq([existing_account.id])
      expect(lead.reload.is_converted).to be_falsey
    end

    it 'with account_mode new, makes a second account with the same name' do
      expect {
        post "/api/crm/leads/#{lead.id}/convert",
             params: { account_name: 'Dorothy Hughes', account_mode: 'new' }.to_json,
             headers: auth_headers
      }.to change(Account, :count).by(1)

      expect(response).to have_http_status(:ok), response.body
      new_id = JSON.parse(response.body).dig('account', 'id')
      expect(new_id).not_to eq(existing_account.id)
      expect(company.accounts.where(name: 'Dorothy Hughes').count).to eq(2)
      expect(Account.find(new_id).phone).to be_present
      expect(Contact.find_by(company_id: company.id, email: 'dhughes@example.com').account_id).to eq(new_id)
      # The other family's account is untouched.
      expect(existing_account.reload.email).to be_blank
      expect(lead.reload.converted_account_id).to eq(new_id)
    end

    it 'with account_id, joins that one of several same-name accounts' do
      second = Account.create!(company_id: company.id, name: 'Dorothy Hughes', status: 'active')

      post "/api/crm/leads/#{lead.id}/convert",
           params: { account_name: 'Dorothy Hughes', account_mode: 'existing', account_id: second.id }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:ok), response.body
      expect(JSON.parse(response.body).dig('account', 'id')).to eq(second.id)
      expect(existing_account.reload.email).to be_blank
    end

    it 'refuses an account_id from another company' do
      other = Account.create!(company_id: Company.create!(name: "Other-#{SecureRandom.hex(4)}").id, name: 'Dorothy Hughes')

      post "/api/crm/leads/#{lead.id}/convert",
           params: { account_name: 'Dorothy Hughes', account_mode: 'existing', account_id: other.id }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:not_found)
      expect(lead.reload.is_converted).to be_falsey
    end

    it 'does not ask about a deleted account with that name' do
      existing_account.update_columns(is_deleted: true)

      post "/api/crm/leads/#{lead.id}/convert",
           params: { account_name: 'Dorothy Hughes' }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:ok), response.body
      expect(JSON.parse(response.body).dig('account', 'id')).not_to eq(existing_account.id)
    end

    it 'with account_mode existing, reuses the account and backfills its missing phone/email' do
      expect {
        post "/api/crm/leads/#{lead.id}/convert",
             params: { account_name: 'Dorothy Hughes', account_mode: 'existing' }.to_json,
             headers: auth_headers
      }.not_to change(Account, :count) # matched, not duplicated

      expect(response).to have_http_status(:ok)
      existing_account.reload
      # Account normalizes phone on save; the point is it's now populated.
      expect(existing_account.phone).to eq('574-555-5004')
      expect(existing_account.email).to eq('dhughes@example.com')
      # Pre-existing address is preserved, not overwritten.
      expect(existing_account.billing_street).to eq('999 Old Rd')
    end
  end
end
