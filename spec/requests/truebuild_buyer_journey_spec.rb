# frozen_string_literal: true

require 'rails_helper'

# A buyer designs and saves a home, gets a portal login that shows only their
# designs, the rep converts them, and a quote is built from the design.
RSpec.describe 'TrueBuild buyer journey', type: :request do
  include ActiveJob::TestHelper

  let(:company) do
    create(:company, name: 'Summit Homes').tap do |c|
      c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) # TrueBuild on the plan
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

  def claim(design)
    get '/api/portal/auth/claim_design', params: { token: Truebuild::PortalAccess.claim_token(design) }
    JSON.parse(response.body)
  end

  it 'invites the buyer by email, makes the login when they click, and that login sees designs and nothing else' do
    design = nil
    expect { design = save_design }.to have_enqueued_mail(BuyerPortalMailer, :truebuild_design_email)
    expect(BuyerPortalAccess.find_by(email: 'tia@example.com')).to be_nil # nothing until they prove the inbox
    expect(design.reload.metadata['portal']).to include('state' => 'invited')

    mail = BuyerPortalMailer.truebuild_design_email(design)
    expect(mail.subject).to eq('Your Belvidere design is saved')
    expect(mail.body.encoded).to include('Stainless Fridge', '$101,250', 'magic-link?claim=', 'next=designs')
    expect(mail.body.encoded).not_to match(/\u2014|\u2013/)
    # "Just reply" reaches the dealer: their name on it, the reply threaded onto the lead.
    expect(mail[:from].display_names).to eq([company.name])
    expect(mail.reply_to.first).to match(/\Areply\+lead-#{design.lead_id}@/)

    body = claim(design)
    expect(body).to include('success' => true)
    access = BuyerPortalAccess.find_by!(email: 'tia@example.com')
    expect(access).to have_attributes(buyer: design.lead, company_id: company.id, portal_enabled: true)
    expect(claim(design)['success']).to be(true) # the link signs in again, making nothing new
    expect(BuyerPortalAccess.where(email: 'tia@example.com').count).to eq(1)

    portal = { 'Authorization' => "Bearer #{body['token']}" }
    get '/api/portal/truebuild_designs', headers: portal
    expect(JSON.parse(response.body)['designs'].first).to include('plan' => 'Belvidere', 'price' => 101_250.0,
                                                                   'options' => ['Stainless Fridge'])
    get '/api/portal/quotes', headers: portal
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)['code']).to eq('lead_portal')

    get '/api/portal/auth/claim_design', params: { token: 'forged' }
    expect(response).to have_http_status(:unauthorized)
  end

  it "never gives a login to a lead whose email is not the saver's (a phone match merged them)" do
    design = save_design
    someone_else = company.leads.create!(first_name: 'Ana', last_name: 'Lee', email: 'ana@example.com', status: 'new')
    design.update!(lead: someone_else)

    Truebuild::PortalAccess.call(design)
    expect(design.reload.metadata['portal']).to eq('state' => 'lead_email_mismatch')
    expect(claim(design)['success']).to be(false)
    expect(BuyerPortalAccess.where(buyer: someone_else)).to be_empty
  end

  it 'moves the login and designs to the contact on conversion, then quotes the design' do
    design = save_design
    claim(design)
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

  describe 'follow up on a shared design' do
    def events(type) = WorkflowEvent.where(event_type: type)

    it 'raises saved, viewed (once an hour), shared and copied on the buyer, and counts them' do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      design = save_design
      expect(events('lead.design_saved').pluck(:entity_id)).to eq([design.lead_id])

      2.times { get "/public/truebuild/designs/#{design.public_token}", params: { token: company.public_inventory_token } }
      expect(design.reload.view_count).to eq(2)
      expect(events('lead.design_viewed').count).to eq(1)

      post "/public/truebuild/designs/#{design.public_token}/events", params: { token: company.public_inventory_token, type: 'shared' }
      expect(response).to have_http_status(:no_content)
      expect(design.reload.share_count).to eq(1)
      expect(events('lead.design_shared').first.payload).to include('design_id' => design.id)

      # A family member saves their own copy from the link.
      post '/public/truebuild/designs', params: {
        token: company.public_inventory_token, variant_id: variant.id, vehicle_id: vehicle.id, option_ids: [fridge.id],
        copied_from: design.public_token, contact: { first_name: 'Sam', last_name: 'May', email: 'sam@example.com' }
      }
      copy = TruebuildDesign.last
      expect(copy.metadata['copied_from']).to eq(design.id)
      expect(design.reload.metadata['copies']).to eq(1)
      expect(events('lead.design_copied').first).to have_attributes(entity_id: design.lead_id)
      expect(events('lead.design_copied').first.payload).to include('copied_by' => 'Sam May')
    end

    it 'does not count the buyer saving a new version of their own design as a copy' do
      design = save_design
      post '/public/truebuild/designs', params: {
        token: company.public_inventory_token, variant_id: variant.id, vehicle_id: vehicle.id, option_ids: [],
        copied_from: design.public_token, contact: { first_name: 'Tia', last_name: 'May', email: 'tia@example.com' }
      }
      expect(events('lead.design_copied')).to be_empty
    end
  end
end
