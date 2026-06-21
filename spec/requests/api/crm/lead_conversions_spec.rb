# frozen_string_literal: true

require 'rails_helper'

# Regression coverage for two lead->account conversion bugs:
#   1. A lead activity with a NULL description aborted the whole conversion
#      (account_activities.description was NOT NULL while lead_activities allows
#      null). Conversion must now succeed and migrate the activity.
#   2. Converting a lead into a PRE-EXISTING account (matched by name) must
#      backfill the account's missing phone/email/address from the lead.
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

    it 'reuses the account and backfills its missing phone/email' do
      expect {
        post "/api/crm/leads/#{lead.id}/convert",
             params: { account_name: 'Dorothy Hughes' }.to_json,
             headers: auth_headers
      }.not_to change(Account, :count) # matched, not duplicated

      expect(response).to have_http_status(:ok)
      existing_account.reload
      # Account normalizes phone on save; the point is it's now populated.
      expect(existing_account.phone).to eq('5745555004')
      expect(existing_account.email).to eq('dhughes@example.com')
      # Pre-existing address is preserved, not overwritten.
      expect(existing_account.billing_street).to eq('999 Old Rd')
    end
  end
end
