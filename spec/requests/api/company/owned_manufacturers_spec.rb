# frozen_string_literal: true

require 'rails_helper'

# Companies can add/manage their own manufacturers (company_id set), alongside the
# global/platform set (company_id nil). Tenant isolation: company_id is never taken
# from params, and a company can't touch another company's owned manufacturer.
RSpec.describe 'Company-owned manufacturers', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  describe 'POST /api/company/manufacturers/owned' do
    it 'creates a company-owned manufacturer and links it to the company' do
      expect do
        post '/api/company/manufacturers/owned',
             params: { manufacturer: { name: 'Custom Modular Co', industry_type: 'manufactured_home',
                                       claim_email: 'claims@custom.com', contact_name: 'Pat Rep' } },
             headers: headers
      end.to change(Manufacturer, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['owned']).to be(true)
      expect(body['claimEmail']).to eq('claims@custom.com')

      m = Manufacturer.find(body['id'])
      expect(m.company_id).to eq(company.id)
      expect(company.company_manufacturers.exists?(manufacturer_id: m.id)).to be(true)
    end

    it 'ignores a company_id passed in params (tenant isolation)' do
      other = Company.create!(name: 'Other', industry: 'manufactured_housing')
      post '/api/company/manufacturers/owned',
           params: { manufacturer: { name: 'Sneaky', industry_type: 'rv', company_id: other.id } },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(Manufacturer.find(JSON.parse(response.body)['id']).company_id).to eq(company.id)
    end
  end

  describe 'GET /api/company/manufacturers' do
    it 'lists the global set plus the company-owned ones, flagged owned' do
      Manufacturer.create!(name: 'Global Co', industry_type: 'manufactured_home') # global (company_id nil)
      owned = Manufacturer.create!(name: 'Mine Co', industry_type: 'manufactured_home', company_id: company.id)

      get '/api/company/manufacturers', headers: headers
      expect(response).to have_http_status(:ok)
      rows = JSON.parse(response.body)['manufacturers']
      mine = rows.find { |r| r['id'] == owned.id }
      glob = rows.find { |r| r['name'] == 'Global Co' }
      expect(mine['owned']).to be(true)
      expect(glob['owned']).to be(false)
    end
  end

  describe 'update / destroy isolation' do
    it 'updates an owned manufacturer' do
      m = Manufacturer.create!(name: 'Mine', industry_type: 'rv', company_id: company.id)
      patch "/api/company/manufacturers/owned/#{m.id}",
            params: { manufacturer: { claim_email: 'new@mine.com' } }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(m.reload.claim_email).to eq('new@mine.com')
    end

    it "404s when touching another company's owned manufacturer" do
      other = Company.create!(name: 'Other', industry: 'rv')
      foreign = Manufacturer.create!(name: 'Theirs', industry_type: 'rv', company_id: other.id)
      patch "/api/company/manufacturers/owned/#{foreign.id}",
            params: { manufacturer: { claim_email: 'x@y.com' } }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it 'destroys an owned manufacturer without claims' do
      m = Manufacturer.create!(name: 'Temp', industry_type: 'rv', company_id: company.id)
      company.company_manufacturers.create!(manufacturer_id: m.id, active: true)
      delete "/api/company/manufacturers/owned/#{m.id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Manufacturer.exists?(m.id)).to be(false)
    end
  end
end
