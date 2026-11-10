# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1 account links', type: :request do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:other)   { Company.create!(name: "O-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Bo', last_name: 'Keeper',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:base) { '/api/v1/account_links' }

  let(:location)       { company.locations.create!(name: "Loc-#{SecureRandom.hex(3)}", timezone: 'UTC') }
  let(:other_location) { other.locations.create!(name: "Theirs-#{SecureRandom.hex(3)}", timezone: 'UTC') }
  let(:revenues)       { company.chart_of_accounts.active.postable.where(account_type: 'revenue').order(:account_number).to_a }
  let(:other_revenue)  { other.chart_of_accounts.active.postable.where(account_type: 'revenue').first }

  def json = JSON.parse(response.body)

  def link_body(**over)
    { account_link: { linkable_type: 'Location', linkable_id: location.id, link_purpose: 'revenue',
                      chart_of_account_id: revenues[1].id, priority: 0, is_active: true }.merge(over) }
  end

  before do
    AccountingSettings.for_company(company).update!(default_sales_revenue_account: revenues[0])
  end

  describe 'GET index' do
    it 'lists inactive mappings too, so they show as Off' do
      on  = company.account_links.create!(linkable: location, chart_of_account: revenues[1], link_purpose: 'revenue')
      off = company.account_links.create!(linkable: location, chart_of_account: revenues[2], link_purpose: 'cogs', is_active: false)
      get base, headers: headers
      expect(response).to have_http_status(:ok)
      expect(json.map { |l| l['id'] }).to contain_exactly(on.id, off.id)
      expect(json.find { |l| l['id'] == off.id }['is_active']).to be(false)
    end
  end

  describe 'POST create' do
    it 'creates a mapping on one of the company\'s locations' do
      post base, params: link_body, headers: headers, as: :json
      expect(response).to have_http_status(:created)
    end

    it 'refuses another company\'s location' do
      post base, params: link_body(linkable_id: other_location.id), headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(company.account_links.count).to eq(0)
    end

    it 'refuses another company\'s GL account' do
      post base, params: link_body(chart_of_account_id: other_revenue.id), headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'refuses a record type it cannot check' do
      post base, params: link_body(linkable_type: 'User', linkable_id: user.id), headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'PATCH update' do
    let!(:link) { company.account_links.create!(linkable: location, chart_of_account: revenues[1], link_purpose: 'revenue') }

    it 'refuses moving a mapping onto another company\'s location' do
      patch "#{base}/#{link.id}", params: { account_link: { linkable_id: other_location.id } }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(link.reload.linkable_id).to eq(location.id)
    end

    it 'refuses another company\'s GL account' do
      patch "#{base}/#{link.id}", params: { account_link: { chart_of_account_id: other_revenue.id } }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(link.reload.chart_of_account_id).to eq(revenues[1].id)
    end

    it 'still lets the mapping be switched off' do
      patch "#{base}/#{link.id}", params: { account_link: { is_active: false } }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(link.reload.is_active).to be(false)
    end
  end

  describe 'POST resolve' do
    it 'answers what a deal at a mapped location will post to' do
      company.account_links.create!(linkable: location, chart_of_account: revenues[1], link_purpose: 'revenue')
      contact = company.contacts.create!(first_name: 'Pat', last_name: 'B', email: "p#{SecureRandom.hex(3)}@example.com")
      deal = company.deals.create!(name: 'Sale', contact_id: contact.id, location_id: location.id)
      post "#{base}/resolve", params: { entity_type: 'Deal', entity_id: deal.id, purpose: 'revenue' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json.dig('resolved_account', 'id')).to eq(revenues[1].id)
    end

    it 'falls back to the default like posting does' do
      post "#{base}/resolve", params: { entity_type: 'Location', entity_id: location.id, purpose: 'revenue' }, headers: headers, as: :json
      expect(json.dig('resolved_account', 'id')).to eq(revenues[0].id)
    end

    it 'does not turn request input into a class' do
      post "#{base}/resolve", params: { entity_type: 'User', entity_id: user.id, purpose: 'revenue' }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'does not find another company\'s record' do
      post "#{base}/resolve", params: { entity_type: 'Location', entity_id: other_location.id, purpose: 'revenue' }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
