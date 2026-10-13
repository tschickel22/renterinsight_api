# frozen_string_literal: true

require 'rails_helper'

# Phones are stored as 303-586-4420; a search typed as digits still finds them.
RSpec.describe 'Searching by phone number', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@ex.com", first_name: 'A', last_name: 'D', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }

  it 'finds a lead by digits or by the stored format' do
    lead = company.leads.create!(first_name: 'Pat', last_name: 'Smith', phone: '3035864420')
    company.leads.create!(first_name: 'Other', last_name: 'Person', phone: '7205551234')
    %w[3035864420 586-4420 (303)586].each do |q|
      get '/api/crm/leads', params: { search: q }, headers: headers
      ids = Array(JSON.parse(response.body).then { |b| b['leads'] || b['items'] || b['data'] || b }).map { |l| l['id'] }
      expect(ids).to eq([lead.id]), q
    end
  end

  it 'finds an account by digits' do
    account = company.accounts.create!(name: 'Smith Household', phone: '(303) 586-4420')
    get '/api/v1/accounts', params: { search: '3035864420' }, headers: headers
    body = JSON.parse(response.body)
    ids = Array(body['accounts'] || body['items'] || body['data']).map { |a| a['id'] }
    expect(ids).to eq([account.id])
  end
end
