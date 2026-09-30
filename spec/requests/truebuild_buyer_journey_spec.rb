# frozen_string_literal: true

require 'rails_helper'

# A buyer designs and saves a home, gets a portal login that shows only their
# designs, the rep converts them, and a quote is built from the design.
RSpec.describe 'TrueBuild buyer journey', type: :request do
  include ActiveJob::TestHelper

  let(:company) do
    create(:company, name: 'Summit Homes').tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8), public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P', password: 'Pass1234!',
                 company_id: company.id, role: 'platform_admin')
  end
  let(:rep_headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}" } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Belvidere') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32392', width_ft: 28, length_ft: 56) }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published', published_at: Time.current) }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'kitchen', name: 'Kitchen') }
  let!(:fridge) do
    CatalogOption.create!(group: group, manufacturer: mfr, key: 'kitchen--fridge', name: 'Stainless Fridge').tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 1000)
    end
  end
  let!(:vehicle) do
    Vehicle.create!(company: company, year: 2026, make: 'Champion', model: 'Belvidere', vin: "VIN#{SecureRandom.hex(6).upcase}",
                    status: 'available', is_deleted: false, catalog_plan_variant: variant)
  end

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 80_000)
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    company.dealer_catalog_terms.create!(price_display: 'full')
  end

  def save_design
    post '/public/truebuild/designs', params: {
      token: company.public_inventory_token, variant_id: variant.id, vehicle_id: vehicle.id, option_ids: [fridge.id],
      contact: { first_name: 'Tia', last_name: 'May', email: 'tia@example.com' }
    }
    TruebuildDesign.last
  end

  it 'gives the buyer a lead-level portal login that sees designs and nothing else' do
    design = nil
    expect { design = save_design }.to have_enqueued_mail(BuyerPortalMailer, :truebuild_design_email)
    access = BuyerPortalAccess.find_by!(email: 'tia@example.com')
    expect(access).to have_attributes(buyer: design.lead, company_id: company.id, portal_enabled: true)
    expect(access.login_token_expires_at).to be > 6.days.from_now
    expect(design.reload.metadata['portal']).to include('state' => 'created')
    mail = BuyerPortalMailer.truebuild_design_email(access, design, magic: true)
    expect(mail.subject).to eq('Your Belvidere design is saved')
    expect(mail.body.encoded).to include('Stainless Fridge', '$101,250', "magic-link?token=#{access.login_token}&amp;next=designs")
    expect(mail.body.encoded).not_to match(/—|–/)

    portal = { 'Authorization' => "Bearer #{JsonWebToken.encode(buyer_portal_access_id: access.id)}" }
    get '/api/portal/truebuild_designs', headers: portal
    expect(JSON.parse(response.body)['designs'].first).to include('plan' => 'Belvidere', 'price' => 101_250.0,
                                                                   'options' => ['Stainless Fridge'])
    get '/api/portal/quotes', headers: portal
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)['code']).to eq('lead_portal')
  end

  it 'moves the login and designs to the contact on conversion, then quotes the design' do
    design = save_design
    post "/api/v1/truebuild_designs/#{design.id}/quote", headers: rep_headers
    expect(response).to have_http_status(:unprocessable_entity)

    post "/api/crm/leads/#{design.lead_id}/convert", headers: rep_headers.merge('Content-Type' => 'application/json'),
                                                    params: { create_contact: true, create_deal: { name: 'Tia home' } }.to_json
    expect(response).to have_http_status(:ok)
    design.reload
    expect(design.contact).to be_present
    expect(design.deal).to have_attributes(value: 101_250.0)
    expect(BuyerPortalAccess.find_by!(email: 'tia@example.com')).to have_attributes(buyer_type: 'Contact', buyer_id: design.contact_id)

    post "/api/v1/truebuild_designs/#{design.id}/quote", headers: rep_headers
    expect(response).to have_http_status(:created)
    quote = Quote.find(JSON.parse(response.body)['id'])
    expect(quote).to have_attributes(contact_id: design.contact_id, deal_id: design.deal_id, total: 101_250.0)
    expect(quote.items.map { |i| i['description'] }).to eq(['Belvidere (2856H32392)', 'Stainless Fridge'])
    expect(design.reload.quote).to eq(quote)

    post "/api/v1/truebuild_designs/#{design.id}/quote", headers: rep_headers
    expect(JSON.parse(response.body)['id']).to eq(quote.id)
  end

  it 'leaves a login at another dealer alone' do
    other = create(:company)
    other_contact = Contact.create!(company_id: other.id, first_name: 'Tia', last_name: 'May', email: 'tia@example.com')
    BuyerPortalAccess.create!(buyer: other_contact, company_id: other.id, email: 'tia@example.com', password: 'Secret123!',
                              password_confirmation: 'Secret123!', portal_enabled: true)
    design = save_design
    expect(design.reload.metadata['portal']).to eq('state' => 'exists_at_another_dealer')
    expect(BuyerPortalAccess.where(email: 'tia@example.com').count).to eq(1)
  end
end
