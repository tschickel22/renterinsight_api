# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::TruebuildDesigns', type: :request do
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Belvidere') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32392', width_ft: 28, length_ft: 56) }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'kitchen', name: 'Kitchen') }
  let(:fridge) do
    CatalogOption.create!(group: group, manufacturer: mfr, key: 'kitchen--fridge', name: 'Stainless Fridge').tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 1000)
    end
  end
  let(:lead) { company.leads.create!(first_name: 'Tia', last_name: 'May', email: 'tia@example.com') }

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 80_000)
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
  end

  it "lists a lead's designs with the price shown then and the price today" do
    company.truebuild_designs.create!(variant: variant, lead: lead, option_ids: [fridge.id], name: 'Belvidere (2856H32392)',
                                      price_snapshot: { 'show_prices' => true, 'total' => 99_000.0 },
                                      metadata: { 'page_url' => 'https://summit.example.com/homes/belvidere-1?utm=x' })
    other = Company.create!(name: "Other #{SecureRandom.hex(3)}")
    other.truebuild_designs.create!(variant: variant, option_ids: [], name: 'Not theirs')

    get '/api/v1/truebuild_designs', params: { lead_id: lead.id }, headers: headers
    designs = JSON.parse(response.body)['designs']
    expect(designs.size).to eq(1)
    expect(designs.first).to include('lead_id' => lead.id, 'options' => ['Stainless Fridge'], 'price_shown' => 99_000.0, 'price_today' => 101_250.0)
    expect(designs.first['link']).to start_with('https://summit.example.com/homes/belvidere-1?design=')

    get '/api/v1/truebuild_designs', params: { deal_id: 0 }, headers: headers
    expect(JSON.parse(response.body)['designs']).to be_empty
  end

  it 'lets a contact with a design be deleted; the design just loses the link' do
    contact = Contact.create!(company_id: company.id, first_name: 'Tia', last_name: 'May', email: 'tia@example.com')
    design = company.truebuild_designs.create!(variant: variant, lead: lead, contact: contact, name: 'Belvidere')
    contact.destroy!
    expect(design.reload.contact_id).to be_nil
  end
end
