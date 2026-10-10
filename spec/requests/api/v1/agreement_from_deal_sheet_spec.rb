# frozen_string_literal: true

require 'rails_helper'

# Create agreement, from the Deal Sheet: the dealer's package rendered for
# the deal, stored as the agreement's document with its signing fields and
# the rep's fields, the buyers, rep and manager as signers in the package's
# order, and the Deal Sheet version recorded. What blocks it is said plainly.
RSpec.describe 'Agreement from the Deal Sheet', type: :request do
  let(:packet) { JSON.parse(File.read(Rails.root.join('script/agreement_templates/fdhc_indiana_packet.json'))) }
  let(:company) { Company.create!(name: "Factory Direct #{SecureRandom.hex(3)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let!(:template) { company.agreement_templates.create!(name: 'FD Packet', status: 'active', template_type: 'upload', packet: packet) }
  let(:mfr) { Manufacturer.create!(name: 'Champion Home Builders', industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Bay Port') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32168', width_ft: 28, length_ft: 56) }
  let(:rep) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let!(:manager) { User.create!(email: "mgr-#{SecureRandom.hex(4)}@example.com", first_name: 'Max', last_name: 'Manager', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Bay Port', contact_id: buyer.id, owner_id: rep.id) }
  let(:path) { "/api/v1/deals/#{deal.id}/home_build/agreement" }

  def body = JSON.parse(response.body)

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    Truebuild::DealBuild.start(deal: deal, variant: variant)
  end

  it 'makes a draft agreement from the package with the buyers, rep and manager signing' do
    get path, headers: headers
    expect(body['templates'].map { |t| t['name'] }).to eq(['FD Packet'])
    expect(body['managers'].map { |m| m['name'] }).to include('Max Manager')
    expect(body['check']['blocking']).to be_empty
    expect(body['check']['open']).to include('Deal Sheet: Cash or finance')

    post path, headers: headers, params: { template_id: template.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('Choose the manager')

    post path, headers: headers, params: { template_id: template.id, manager_id: manager.id }.to_json
    expect(response).to have_http_status(:created)
    agreement = company.agreements.find(body['agreement']['id'])
    expect(agreement).to have_attributes(status: 'draft', deal_id: deal.id, contact_id: buyer.id, agreement_template_id: template.id)
    expect(agreement.document_url).to be_present
    expect(agreement).to have_attributes(content_type: 'pdf_upload', document_urls: [agreement.read_attribute(:document_url)])
    expect(agreement.agreement_signers.order(:signing_order, :id).map(&:name)).to eq(['Pat Smith', 'Rita Rep', 'Max Manager'])
    signer_fields = agreement.field_placements.select { |p| p['isSignerField'] }
    expect(signer_fields.map { |p| p['signerIndex'] }.uniq).to contain_exactly(0, 1, 2)
    expect(agreement.custom_field_definitions.map { |d| d['key'] }).to include('page1_f40')
    expect(agreement.metadata['deal_sheet']['version_number']).to eq(1)
    expect(agreement.deal_sheet_status).to include(live: true, changed: false)

    get path, headers: headers
    expect(body['agreements'].map { |a| a['number'] }).to eq([agreement.agreement_number])
  end

  it 'says what blocks it' do
    buyer.update!(email: nil) if buyer.respond_to?(:email=)
    get path, headers: headers
    expect(body['check']['blocking']).to include('The buyer needs an email address to sign')
    post path, headers: headers, params: { manager_id: manager.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('email address')
  end

  it 'installs a package for a company from the platform admin, only when the name matches' do
    admin = User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A', password: 'Pass1234!',
                         company_id: company.id, role: 'platform_admin')
    auth = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
    template.update!(is_deleted: true)

    get '/api/admin/agreement_packages', headers: auth
    expect(body['packages'].map { |p| p['package'] }).to include('fdhc_indiana')

    post '/api/admin/agreement_packages', headers: auth, params: { company_id: company.id, package: 'fdhc_indiana', expect: 'Someone Else' }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    post '/api/admin/agreement_packages', headers: auth, params: { company_id: company.id, package: 'fdhc_indiana', expect: 'Factory Direct' }.to_json
    expect(body['preview']).to start_with('Create')
    expect(company.agreement_templates.where(is_deleted: false)).to be_empty

    post '/api/admin/agreement_packages', headers: auth, params: { company_id: company.id, package: 'fdhc_indiana', expect: 'Factory Direct', apply: true }.to_json
    expect(response).to have_http_status(:created)
    expect(body['installed']).to start_with('Create')
    installed = company.agreement_templates.find(body['template']['id'])
    expect(installed).to be_packet
    post '/api/admin/agreement_packages', headers: auth, params: { company_id: company.id, package: 'fdhc_indiana', expect: 'Factory Direct', apply: true }.to_json
    expect(body['template']['id']).to eq(installed.id) # a re-run updates in place
    expect(body['installed']).to start_with('Update')

    get '/api/admin/agreement_packages', headers: headers
    expect(response).to have_http_status(:forbidden)
  end
end
