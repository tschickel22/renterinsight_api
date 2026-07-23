# frozen_string_literal: true

require 'rails_helper'

# Covers POST /api/crm/leads/bulk_add_tags — the "select all matching" tagging
# path so a user can tag the whole filtered set (every page), not just the
# visible selection. Accepts an explicit lead_ids batch OR the same filter
# #index/#bulk_reassign use, and resolves tags by id or name.
RSpec.describe 'Api::Crm::Leads bulk_add_tags', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  def make_lead(attrs = {})
    Lead.create!({ company_id: company.id, first_name: 'A', last_name: 'B',
                   email: "l-#{SecureRandom.hex(4)}@x.com", status: 'new' }.merge(attrs))
  end

  def tags_on(lead)
    TagAssignment.where(entity_type: 'Lead', entity_id: lead.id).includes(:tag).map { |a| a.tag.name }
  end

  describe 'explicit lead_ids' do
    it 'creates a tag by name and applies it to the given leads' do
      l1 = make_lead
      l2 = make_lead
      post '/api/crm/leads/bulk_add_tags',
           params: { lead_ids: [l1.id, l2.id], tag_names: ['VIP'] }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['tagged_count']).to eq(2)
      expect(body['assignments_created']).to eq(2)
      expect(tags_on(l1)).to include('VIP')
      expect(tags_on(l2)).to include('VIP')
    end

    it 'is idempotent — re-tagging an already-tagged lead adds nothing' do
      l1 = make_lead
      2.times do
        post '/api/crm/leads/bulk_add_tags',
             params: { lead_ids: [l1.id], tag_names: ['Hot'] }.to_json,
             headers: auth_headers
      end
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['assignments_created']).to eq(0) # second call
      expect(TagAssignment.where(entity_type: 'Lead', entity_id: l1.id).count).to eq(1)
    end

    it 'reuses an existing tag by id rather than creating a duplicate' do
      tag = Tag.create!(name: 'Existing', color: '#111', is_active: true, created_by: 'system')
      l1 = make_lead
      expect {
        post '/api/crm/leads/bulk_add_tags',
             params: { lead_ids: [l1.id], tag_ids: [tag.id] }.to_json,
             headers: auth_headers
      }.not_to change { Tag.count }
      expect(tags_on(l1)).to eq(['Existing'])
    end
  end

  describe 'filter ("select all matching")' do
    it 'tags every lead matching the filter, across pages' do
      matching = Array.new(3) { make_lead(owner_id: user.id) }
      other    = make_lead(owner_id: nil)

      post '/api/crm/leads/bulk_add_tags',
           params: { filter: { owner_id: user.id }, tag_names: ['Mine'] }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['tagged_count']).to eq(3)
      matching.each { |l| expect(tags_on(l)).to include('Mine') }
      expect(tags_on(other)).not_to include('Mine')
    end
  end

  describe 'validation' do
    it '400s when no tags are provided' do
      l1 = make_lead
      post '/api/crm/leads/bulk_add_tags',
           params: { lead_ids: [l1.id] }.to_json, headers: auth_headers
      expect(response).to have_http_status(:bad_request)
    end

    it '400s when neither lead_ids nor filter is provided' do
      post '/api/crm/leads/bulk_add_tags',
           params: { tag_names: ['X'] }.to_json, headers: auth_headers
      expect(response).to have_http_status(:bad_request)
    end

    it 'does not tag leads from another company' do
      other_company = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      foreign = Lead.create!(company_id: other_company.id, first_name: 'X', last_name: 'Y',
                             email: 'f@x.com', status: 'new')
      post '/api/crm/leads/bulk_add_tags',
           params: { lead_ids: [foreign.id], tag_names: ['Nope'] }.to_json,
           headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['tagged_count']).to eq(0)
      expect(tags_on(foreign)).to be_empty
    end
  end
end
