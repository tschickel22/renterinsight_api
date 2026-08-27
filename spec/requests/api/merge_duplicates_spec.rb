# frozen_string_literal: true

require 'rails_helper'

# Find & merge duplicates, exercised through the HTTP surface for all three CRM
# entities. The merge rewrites foreign keys across dozens of tables, so the
# tenant-isolation cases here matter as much as the happy path.
RSpec.describe 'Find & merge duplicates', type: :request do
  let(:company)       { create(:company, use_rbac_system: false) }
  let(:other_company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "merge-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Ada', last_name: 'Reyes')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  def contact(attrs = {})
    Contact.create!({ company_id: company.id, first_name: 'Bob', last_name: 'Smith' }.merge(attrs))
  end

  describe 'GET /api/v1/contacts/:id/duplicates' do
    it 'finds a same-person record written a different way and explains why' do
      keeper = contact(email: 'bob@example.com', phone: '(720) 555-1234')
      dupe   = contact(first_name: 'Robert', email: 'BOB@EXAMPLE.COM', phone: '7205551234')

      get "/api/v1/contacts/#{keeper.id}/duplicates", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      ids  = body['duplicates'].map { |d| d['id'] }
      expect(ids).to include(dupe.id)

      match = body['duplicates'].find { |d| d['id'] == dupe.id }
      expect(match['reasons']).to include('same email', 'same phone')
      expect(match['strong_match']).to be(true)
      expect(match['differing_fields'].map { |f| f['field'] }).to include('first_name')
    end

    it 'never proposes another company record as a duplicate' do
      keeper = contact(email: 'bob@example.com')
      Contact.create!(company_id: other_company.id, first_name: 'Bob',
                      last_name: 'Smith', email: 'bob@example.com')

      get "/api/v1/contacts/#{keeper.id}/duplicates", headers: headers

      expect(JSON.parse(response.body)['duplicates']).to be_empty
    end

    it 'does not call two different people with the same surname a duplicate' do
      keeper = contact(first_name: 'Dave', last_name: 'Johnson', email: 'dave@a.com')
      contact(first_name: 'Karen', last_name: 'Johnson', email: 'karen@b.com')

      get "/api/v1/contacts/#{keeper.id}/duplicates", headers: headers

      expect(JSON.parse(response.body)['duplicates']).to be_empty
    end
  end

  describe 'POST /api/v1/contacts/:id/merge_preview' do
    it 'reports what would move without changing anything' do
      keeper = contact(email: 'bob@example.com', phone: nil)
      dupe   = contact(email: 'bob@example.com', phone: '720-555-1234')
      quote  = Quote.create!(company_id: company.id, contact_id: dupe.id)

      post "/api/v1/contacts/#{keeper.id}/merge_preview",
           params: { duplicate_id: dupe.id }, headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['preview']).to be(true)
      expect(body['moved']).to include('quotes.contact_id' => 1)
      expect(body['fields_taken']).to have_key('phone')

      expect(quote.reload.contact_id).to eq(dupe.id)
      expect(keeper.reload.phone).to be_nil
      expect(dupe.reload.merged_into_id).to be_nil
    end
  end

  describe 'POST /api/v1/contacts/:id/merge' do
    it 'moves the related records, fills blanks and retires the duplicate' do
      keeper = contact(email: 'bob@example.com', phone: nil)
      dupe   = contact(email: 'bob@example.com', phone: '720-555-1234')
      quote  = Quote.create!(company_id: company.id, contact_id: dupe.id)

      post "/api/v1/contacts/#{keeper.id}/merge",
           params: { duplicate_id: dupe.id }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['total_records_moved']).to be >= 1

      expect(quote.reload.contact_id).to eq(keeper.id)
      expect(keeper.reload.phone).to eq('720-555-1234')
      expect(dupe.reload.merged_into_id).to eq(keeper.id)
      expect(Contact.not_merged).not_to include(dupe)
    end

    it 'honours a field the user picked explicitly' do
      keeper = contact(email: 'keep@example.com')
      dupe   = contact(email: 'keep@example.com', first_name: 'Robert')

      post "/api/v1/contacts/#{keeper.id}/merge",
           params: { duplicate_id: dupe.id, field_overrides: { first_name: 'Bobby' } },
           headers: headers

      expect(keeper.reload.first_name).to eq('Bobby')
    end

    it 'refuses to merge a record belonging to another company' do
      keeper  = contact
      foreign = Contact.create!(company_id: other_company.id, first_name: 'Bob', last_name: 'Smith')

      post "/api/v1/contacts/#{keeper.id}/merge",
           params: { duplicate_id: foreign.id }, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.merged_into_id).to be_nil
    end

    it 'requires a duplicate_id rather than guessing' do
      keeper = contact
      post "/api/v1/contacts/#{keeper.id}/merge", params: {}, headers: headers
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'accounts and leads use the same surface' do
    it 'merges accounts' do
      keeper = Account.create!(company_id: company.id, name: 'Summit Park Homes', email: 'a@x.com')
      # Account names are unique per company, which is itself part of why
      # duplicates arrive with slightly different spellings.
      dupe   = Account.create!(company_id: company.id, name: 'Summit Park Homes LLC',
                               email: 'a@x.com', phone: '7205551234')

      post "/api/v1/accounts/#{keeper.id}/merge",
           params: { duplicate_id: dupe.id }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(keeper.reload.phone).to eq('7205551234')
      expect(dupe.reload.merged_into_id).to eq(keeper.id)
    end

    it 'merges leads' do
      keeper = create(:lead, company: company, email: 'lead@x.com')
      dupe   = create(:lead, company: company, email: 'lead@x.com', phone: '7205551234')

      post "/api/crm/leads/#{keeper.id}/merge",
           params: { duplicate_id: dupe.id }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(dupe.reload.merged_into_id).to eq(keeper.id)
    end
  end
end
