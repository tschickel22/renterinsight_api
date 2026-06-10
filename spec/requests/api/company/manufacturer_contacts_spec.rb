# frozen_string_literal: true

require 'rails_helper'
require 'ostruct'

# Per-company manufacturer rep contacts + warranty recipient resolution.
# Global manufacturer holds the factory default contact; each company can store
# their own rep override; warranty claims prefer the override, falling back to
# the factory default.
RSpec.describe 'Company manufacturer contacts', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:manufacturer) do
    Manufacturer.create!(name: 'Acme Homes', industry_type: 'manufactured_housing',
                         contact_name: 'Factory Warranty Dept', contact_email: 'warranty@acme.com',
                         contact_phone: '800-000-0000')
  end

  describe 'POST /api/company/manufacturers' do
    it 'stores the company rep override and exposes effective + factory contacts' do
      post '/api/company/manufacturers',
           params: { manufacturer_id: manufacturer.id, dealer_code: 'D-1',
                     contact_name: 'My Rep', contact_email: 'rep@acme.com', contact_phone: '555-111-2222' },
           headers: headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      # override stored
      expect(body['contactEmailOverride']).to eq('rep@acme.com')
      expect(body['contactNameOverride']).to eq('My Rep')
      # effective = override when present
      expect(body['contactEmail']).to eq('rep@acme.com')
      # factory default still surfaced for reference
      expect(body['factoryContactEmail']).to eq('warranty@acme.com')

      cm = CompanyManufacturer.find_by(company_id: company.id, manufacturer_id: manufacturer.id)
      expect(cm.contact_email).to eq('rep@acme.com')
    end

    it 'falls back to the factory contact when no override is set' do
      post '/api/company/manufacturers',
           params: { manufacturer_id: manufacturer.id, dealer_code: 'D-1' }, headers: headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['contactEmailOverride']).to be_nil
      expect(body['contactEmail']).to eq('warranty@acme.com') # effective falls back to factory
    end
  end

  describe 'WarrantyNotificationService.resolve_manufacturer_email' do
    let(:claim) { OpenStruct.new(company_id: company.id, manufacturer_id: manufacturer.id, manufacturer: manufacturer) }

    it 'falls back to the factory contact email when no claim_email is set' do
      expect(WarrantyNotificationService.resolve_manufacturer_email(claim)).to eq('warranty@acme.com')
    end

    it 'uses the factory claim_email over the generic contact email' do
      manufacturer.update!(claim_email: 'claims@acme.com')
      expect(WarrantyNotificationService.resolve_manufacturer_email(claim)).to eq('claims@acme.com')
    end

    it 'prefers the company claim_email override, ignoring the rep contact email' do
      manufacturer.update!(claim_email: 'claims@acme.com')
      CompanyManufacturer.create!(company_id: company.id, manufacturer_id: manufacturer.id,
                                  contact_email: 'rep@acme.com', # rep — must NOT be the destination
                                  claim_email: 'regional-warranty@acme.com')
      expect(WarrantyNotificationService.resolve_manufacturer_email(claim)).to eq('regional-warranty@acme.com')
    end
  end
end
