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
  # The buyer is on the dealer's DealerTide site (TruebuildReach).
  let!(:site) do
    Website.create!(company_id: company.id, location_id: company.locations.create!(name: 'Main Lot').id, name: 'Summit',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published')
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
      token: company.public_inventory_token, website_id: site.id, variant_id: variant.id, vehicle_id: vehicle.id, option_ids: [fridge.id],
      contact: { first_name: 'Tia', last_name: 'May', email: 'tia@example.com' }
    }
    TruebuildDesign.last
  end

  def claim(design)
    get '/api/portal/auth/claim_design', params: { token: Truebuild::PortalAccess.claim_token(design) }
    JSON.parse(response.body)
  end

  it 'makes the login when the buyer saves, emails a link that signs them in, and that login sees designs and nothing else' do
    design = nil
    expect { design = save_design }.to have_enqueued_mail(BuyerPortalMailer, :truebuild_design_email)
    # There at once, so they can sign in later even without the email.
    expect(BuyerPortalAccess.find_by(email: 'tia@example.com')).to have_attributes(buyer: design.lead, portal_enabled: true)
    expect(design.reload.metadata['portal']).to include('state' => 'created')

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

  it "signs a buyer in from the portal's own magic link page (the response names the buyer)" do
    save_design
    access = BuyerPortalAccess.find_by!(email: 'tia@example.com')
    access.generate_login_token
    get '/api/portal/auth/verify_magic_link', params: { token: access.login_token }
    body = JSON.parse(response.body)
    expect(body['buyer']).to include('id' => access.id, 'email' => 'tia@example.com')
    expect(body['token']).to be_present
  end

  it 'lets a buyer with only a design login sign in from the main app sign in, by magic link' do
    design = save_design
    access = BuyerPortalAccess.find_by!(email: 'tia@example.com')
    allow(BuyerPortalService).to receive(:send_magic_link_email)
    post '/api/auth/request_magic_link', params: { email: 'TIA@example.com' }
    expect(BuyerPortalService).to have_received(:send_magic_link_email).with(access)

    get '/api/auth/verify_magic_link', params: { token: access.reload.login_token }
    body = JSON.parse(response.body)
    expect(body['success']).to be(true)
    portal = { 'Authorization' => "Bearer #{body['token'] || body['access_token']}" }
    get '/api/portal/truebuild_designs', headers: portal
    expect(JSON.parse(response.body)['designs'].map { |d| d['id'] }).to eq([design.id])
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

  it "upgrades the buyer's design-only login to the whole portal when the dealer invites them" do
    design = save_design
    body = claim(design)
    portal = { 'Authorization' => "Bearer #{body['token']}" }

    # Converted under another email, so conversion did not carry the login.
    account = company.accounts.create!(name: 'May Household')
    contact = company.contacts.create!(first_name: 'Tia', last_name: 'May', email: 'tia.may@work.example', account: account)
    design.update!(contact: contact, account: account)

    sent = nil
    allow(CommunicationService).to receive(:send_email) { |**args| sent = args; { success: true } }
    post '/api/v1/portal_users/invite', headers: rep_headers, params: { contact_id: contact.id }
    expect(response).to have_http_status(:ok)
    # She has an account already: the email asks her to sign in, not sign up.
    expect(sent[:subject]).to include('portal has more for you')
    expect(sent[:body]).to include('>Sign in</a>', '/client/login?email=tia%40example.com')
    expect(sent[:body]).not_to include('Create your account')
    expect(JSON.parse(response.body)).to include('upgraded' => true)

    access = BuyerPortalAccess.find_by!(email: 'tia@example.com')
    expect(access).to have_attributes(buyer_type: 'Contact', buyer_id: contact.id)
    expect(BuyerPortalAccess.where(company_id: company.id).count).to eq(1)

    get '/api/portal/quotes', headers: portal
    expect(response).not_to have_http_status(:forbidden)
    get '/api/portal/truebuild_designs', headers: portal
    expect(JSON.parse(response.body)['designs'].size).to eq(1)

    post "/api/portal/truebuild_designs/#{design.id}/shared", headers: portal
    expect(response).to have_http_status(:no_content)
    expect(design.reload.share_count).to eq(1)
    expect(WorkflowEvent.where(event_type: 'contact.design_shared', entity_id: contact.id)).to exist
  end

  it 'tells the registration page when the invited buyer already has an account' do
    design = save_design
    claim(design) # signed in by the emailed link: that is an account
    access = BuyerPortalAccess.find_by!(email: 'tia@example.com')
    access.generate_invitation_token
    get '/api/portal/auth/verify_invitation', params: { token: access.invitation_token }
    expect(JSON.parse(response.body)).to include('ok' => true, 'has_account' => true, 'email' => 'tia@example.com')
  end

  it "does not hand a stranger's design-only login to a contact" do
    design = save_design
    claim(design)
    stranger = company.contacts.create!(first_name: 'Ana', last_name: 'Lee', email: 'tia@example.com')
    allow_any_instance_of(Api::V1::PortalUsersController).to receive(:send_portal_invitation)
    post '/api/v1/portal_users/invite', headers: rep_headers, params: { contact_id: stranger.id }
    expect(BuyerPortalAccess.find_by!(email: 'tia@example.com')).to have_attributes(buyer_type: 'Lead', buyer_id: design.lead_id)
  end

  it 'saves changes from a My Designs link to the signed-in buyer, with no form and no new lead' do
    design = save_design
    portal = { 'Authorization' => "Bearer #{claim(design)['token']}" }
    get '/api/portal/truebuild_designs', headers: portal
    link = JSON.parse(response.body)['designs'].first['link']
    pass = CGI.unescape(link[/[?&]as=([^&]+)/, 1])
    # The link a buyer shares never carries their pass.
    expect(JSON.parse(response.body)['designs'].first['share_link']).not_to include('as=')
    expect(JSON.parse(response.body)['designs'].first['dealer_name']).to eq(company.name)

    get '/public/truebuild/buyer', params: { token: company.public_inventory_token, website_id: site.id, as: pass }
    expect(JSON.parse(response.body)).to include('signed_in' => true, 'first_name' => 'Tia', 'email' => 'tia@example.com')

    leads = Lead.count
    submissions = IntakeSubmission.count
    post '/public/truebuild/designs', params: {
      token: company.public_inventory_token, website_id: site.id, variant_id: variant.id, vehicle_id: vehicle.id, option_ids: [], as: pass, copied_from: design.public_token
    }
    expect(response).to have_http_status(:created)
    version = TruebuildDesign.last
    expect(version).to have_attributes(lead_id: design.lead_id, buyer_email: 'tia@example.com', option_ids: [])
    expect([Lead.count, IntakeSubmission.count]).to eq([leads, submissions])
    expect(WorkflowEvent.where(event_type: 'lead.design_copied')).to be_empty # her own new version

    get '/public/truebuild/buyer', params: { token: company.public_inventory_token, website_id: site.id, as: 'forged' }
    expect(JSON.parse(response.body)).to eq('signed_in' => false)
    other = create(:company).tap { |c| c.update!(public_inventory_token: SecureRandom.hex(8), public_inventory_settings: { 'public_inventory_enabled' => true }) }
    other_site = Website.create!(company_id: other.id, location_id: other.locations.create!(name: 'Lot').id, name: 'Other', slug: "o-#{SecureRandom.hex(4)}")
    get '/public/truebuild/buyer', params: { token: other.public_inventory_token, website_id: other_site.id, as: pass }
    expect(JSON.parse(response.body)).to eq('signed_in' => false)
  end

  it 'saves another version without asking again, and without a second lead or intake entry' do
    post '/public/truebuild/designs', params: {
      token: company.public_inventory_token, website_id: site.id, variant_id: variant.id, vehicle_id: vehicle.id, option_ids: [fridge.id],
      contact: { first_name: 'Sam', last_name: 'May', email: 'sam@example.com' }
    }
    first = TruebuildDesign.last
    pass = JSON.parse(response.body)['pass']
    expect(pass).to be_present

    get '/public/truebuild/buyer', params: { token: company.public_inventory_token, website_id: site.id, as: pass }
    expect(JSON.parse(response.body)).to include('signed_in' => true, 'first_name' => 'Sam', 'email' => 'sam@example.com')

    leads = Lead.count
    submissions = IntakeSubmission.count
    post '/public/truebuild/designs', params: {
      token: company.public_inventory_token, website_id: site.id, variant_id: variant.id, vehicle_id: vehicle.id, option_ids: [], as: pass, copied_from: first.public_token
    }
    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)['pass']).to eq(pass)
    expect(TruebuildDesign.last).to have_attributes(lead_id: first.lead_id, buyer_email: 'sam@example.com')
    expect([Lead.count, IntakeSubmission.count]).to eq([leads, submissions])
  end

  describe 'follow up on a shared design' do
    def events(type) = WorkflowEvent.where(event_type: type)

    it 'raises saved, viewed (once an hour), shared and copied on the buyer, and counts them' do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      design = save_design
      expect(events('lead.design_saved').pluck(:entity_id)).to eq([design.lead_id])

      2.times { get "/public/truebuild/designs/#{design.public_token}", params: { token: company.public_inventory_token, website_id: site.id } }
      expect(design.reload.view_count).to eq(2)
      expect(events('lead.design_viewed').count).to eq(1)

      post "/public/truebuild/designs/#{design.public_token}/events", params: { token: company.public_inventory_token, website_id: site.id, type: 'shared' }
      expect(response).to have_http_status(:no_content)
      expect(design.reload.share_count).to eq(1)
      expect(events('lead.design_shared').first.payload).to include('design_id' => design.id)

      # A family member saves their own copy from the link.
      post '/public/truebuild/designs', params: {
        token: company.public_inventory_token, website_id: site.id, variant_id: variant.id, vehicle_id: vehicle.id, option_ids: [fridge.id],
        copied_from: design.public_token, contact: { first_name: 'Sam', last_name: 'May', email: 'sam@example.com' }
      }
      copy = TruebuildDesign.last
      expect(copy.metadata['copied_from']).to eq(design.id)
      expect(design.reload.metadata['copies']).to eq(1)
      expect(events('lead.design_copied').first).to have_attributes(entity_id: design.lead_id)
      expect(events('lead.design_copied').first.payload).to include('copied_by' => 'Sam May')

      # Sam's lead says it came from Tia's share, and reports as a share.
      sam = Lead.find(copy.lead_id)
      expect(sam).to have_attributes(utm_medium: 'share', utm_campaign: 'design_share')
      expect(sam.source&.name).to eq(Truebuild::DesignSaver::SOURCE)
      expect(copy.intake_submission.data['Message']).to start_with('Shared with them by Tia May, from their Belvidere')

      # Each design links to the other in the CRM.
      get '/api/v1/truebuild_designs', headers: rep_headers, params: { lead_id: sam.id }
      expect(JSON.parse(response.body)['designs'].first['shared_from']).to include('buyer_name' => 'Tia May', 'lead_id' => design.lead_id)
      get '/api/v1/truebuild_designs', headers: rep_headers, params: { lead_id: design.lead_id }
      expect(JSON.parse(response.body)['designs'].first['copies'].map { |c| c['buyer_name'] }).to eq(['Sam May'])
    end

    it 'does not count the buyer saving a new version of their own design as a copy' do
      design = save_design
      post '/public/truebuild/designs', params: {
        token: company.public_inventory_token, website_id: site.id, variant_id: variant.id, vehicle_id: vehicle.id, option_ids: [],
        copied_from: design.public_token, contact: { first_name: 'Tia', last_name: 'May', email: 'tia@example.com' }
      }
      expect(events('lead.design_copied')).to be_empty
    end
  end
end
