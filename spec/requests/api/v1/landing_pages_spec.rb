# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::LandingPages', type: :request do
  let(:company) { Company.create!(name: "LPReq-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  # Paid add-on. Campaign Desk grants it implicitly; everyone else needs it
  # added to their subscription.
  before { company.tenant_module_overrides.create!(module_key: 'marketing.landing_pages', is_enabled: true) }

  let(:site) { Marketing::MarketingSiteProvisioner.call(company: company) }
  let(:page) do
    site.website_pages.create!(
      title: 'Spring Sale', path: '/spring-sale', page_kind: 'landing',
      blocks: [{ 'id' => 'b1', 'type' => 'hero', 'order' => 0, 'content' => { 'title' => 'Spring Sale' } }]
    )
  end

  def json = JSON.parse(response.body)

  describe 'POST /api/v1/landing_pages' do
    it 'creates a landing page, provisioning the marketing container on first use' do
      expect(company.websites.marketing_containers).to be_empty

      post '/api/v1/landing_pages',
           params: { title: 'Autumn Offer', layout_id: 'lp-offer-focus' }.to_json,
           headers: headers

      expect(response).to have_http_status(:created)
      expect(json['page_kind']).to eq('landing')
      expect(json['layout_id']).to eq('lp-offer-focus')
      expect(company.websites.marketing_containers.count).to eq(1)
    end

    it 'defaults a new landing page to noindex and unpublished' do
      post '/api/v1/landing_pages', params: { title: 'Autumn Offer' }.to_json, headers: headers

      expect(json['robots']).to eq('noindex, nofollow')
      expect(json['published']).to be(false)
    end

    it 'reuses the container on a second create' do
      2.times do |i|
        post '/api/v1/landing_pages', params: { title: "Offer #{i}" }.to_json, headers: headers
      end
      expect(company.websites.marketing_containers.count).to eq(1)
    end
  end

  describe 'GET /api/v1/landing_pages' do
    it 'lists landing pages with stats' do
      page
      get '/api/v1/landing_pages', headers: headers

      expect(response).to have_http_status(:ok)
      expect(json['items'].map { |i| i['title'] }).to include('Spring Sale')
      expect(json['meta']['stats']).to include('total' => 1, 'draft' => 1, 'published' => 0)
    end

    # Ordinary site pages are a different surface and must not appear here.
    it 'excludes ordinary site pages' do
      site.website_pages.create!(title: 'About Us', path: '/about')
      get '/api/v1/landing_pages', headers: headers

      expect(json['items'].map { |i| i['title'] }).not_to include('About Us')
    end

    it 'filters by campaign' do
      campaign = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                                  campaign_type: 'blast', from_identity_type: 'User',
                                  from_identity_id: user.id, throttle_per_day: 100)
      page.update!(campaign_id: campaign.id)
      site.website_pages.create!(title: 'Unlinked', path: '/unlinked', page_kind: 'landing')

      get "/api/v1/landing_pages?campaign_id=#{campaign.id}", headers: headers
      expect(json['items'].map { |i| i['title'] }).to eq(['Spring Sale'])
    end
  end

  describe 'publish / unpublish' do
    it 'publishes and unpublishes at the page level' do
      post "/api/v1/landing_pages/#{page.id}/publish", headers: headers
      expect(json['published']).to be(true)
      expect(json['public_url']).to end_with('/spring-sale')

      post "/api/v1/landing_pages/#{page.id}/unpublish", headers: headers
      expect(json['published']).to be(false)
    end

    # The container is always site-published; page state is the real gate.
    it 'leaves the container published throughout' do
      post "/api/v1/landing_pages/#{page.id}/unpublish", headers: headers
      expect(site.reload.status).to eq('published')
    end
  end

  describe 'POST /:id/duplicate' do
    it 'returns a fresh unpublished copy' do
      page.publish!

      post "/api/v1/landing_pages/#{page.id}/duplicate", headers: headers

      expect(response).to have_http_status(:created)
      expect(json['title']).to eq('(Copy) Spring Sale')
      expect(json['path']).to eq('/spring-sale-copy')
      expect(json['published']).to be(false)
      expect(json['id']).not_to eq(page.id)
    end

    it 'accepts a title override' do
      post "/api/v1/landing_pages/#{page.id}/duplicate",
           params: { title: 'Summer Sale' }.to_json, headers: headers

      expect(json['title']).to eq('Summer Sale')
    end
  end

  describe 'POST /:id/clone_to_locations' do
    let!(:boulder) { company.locations.create!(name: 'Boulder Showroom') }
    let!(:pueblo)  { company.locations.create!(name: 'Pueblo Showroom') }

    it 'creates one copy per location' do
      post "/api/v1/landing_pages/#{page.id}/clone_to_locations",
           params: { location_ids: [boulder.id, pueblo.id] }.to_json, headers: headers

      expect(response).to have_http_status(:created)
      expect(json['cloned_count']).to eq(2)
      expect(json['failures']).to be_empty
      expect(json['items'].map { |i| i['title'] }).to contain_exactly(
        'Spring Sale — Boulder Showroom', 'Spring Sale — Pueblo Showroom'
      )
    end

    it 'rejects an empty location list' do
      post "/api/v1/landing_pages/#{page.id}/clone_to_locations",
           params: { location_ids: [] }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to match(/at least one location/i)
    end

    # Locations are resolved through the company, so an id from elsewhere
    # simply is not found.
    it 'ignores locations belonging to another company' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      foreign = other.locations.create!(name: 'Not Ours')

      post "/api/v1/landing_pages/#{page.id}/clone_to_locations",
           params: { location_ids: [foreign.id] }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'tenant isolation' do
    it 'cannot read another company landing page' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      other_site = Marketing::MarketingSiteProvisioner.call(company: other)
      foreign = other_site.website_pages.create!(title: 'Theirs', path: '/theirs', page_kind: 'landing')

      get "/api/v1/landing_pages/#{foreign.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it 'cannot duplicate another company landing page' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      other_site = Marketing::MarketingSiteProvisioner.call(company: other)
      foreign = other_site.website_pages.create!(title: 'Theirs', path: '/theirs', page_kind: 'landing')

      post "/api/v1/landing_pages/#{foreign.id}/duplicate", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /:id' do
    it 'soft-deletes and takes the page offline' do
      page.publish!
      delete "/api/v1/landing_pages/#{page.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      page.reload
      expect(page.is_deleted).to be(true)
      expect(page.published?).to be(false)
    end
  end

  describe 'POST /ai_generate' do
    let(:plan) do
      {
        'profile' => { 'copy' => { 'hero' => [{ 'headline' => 'Spring Sale' }] } },
        'form_fields' => [{ 'name' => 'email', 'type' => 'email', 'required' => true }],
        'layout_hint' => 'lp-offer-focus'
      }
    end

    before do
      allow_any_instance_of(LandingPages::AiBuilder).to receive(:call_claude).and_return(
        text: plan.to_json, model_version: 'claude-test', input_tokens: 10, output_tokens: 20
      )
    end

    # A plan, not a page: projection into blocks happens on the frontend where
    # the layouts live.
    it 'returns profile sections, form fields and a layout hint' do
      post '/api/v1/landing_pages/ai_generate',
           params: { prompt: 'Spring sale, $0 down' }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(json.dig('profile', 'copy', 'hero', 0, 'headline')).to eq('Spring Sale')
      expect(json['layout_hint']).to eq('lp-offer-focus')
      expect(json['form_fields']).to be_present
      expect(json).not_to have_key('usage')
    end

    it 'requires a prompt or a scanned document' do
      post '/api/v1/landing_pages/ai_generate', params: {}.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json['error']).to match(/describe the page/i)
    end

    it 'reports a spent credit limit as payment required' do
      allow_any_instance_of(LandingPages::AiBuilder).to receive(:generate)
        .and_raise(LandingPages::AiBuilder::CreditLimitError, 'Monthly AI credit limit reached (50).')

      post '/api/v1/landing_pages/ai_generate', params: { prompt: 'x' }.to_json, headers: headers

      expect(response).to have_http_status(:payment_required)
    end
  end

  describe 'the intake form on create' do
    # A landing page with no form silently drops every lead.
    it 'builds a form and binds it to the contact block' do
      post '/api/v1/landing_pages',
           params: {
             title: 'Autumn Offer',
             blocks: [{ id: 'b1', type: 'contact', order: 0, content: { title: 'Enquire' } }],
             form_fields: [{ name: 'email', label: 'Email', type: 'email', required: true }]
           }.to_json,
           headers: headers

      expect(response).to have_http_status(:created)
      expect(json['intake_form_id']).to be_present
      expect(json['blocks'].first['content']['intakeFormId']).to eq(json['intake_form_id'])
    end

    it 'falls back to sensible default fields when none are supplied' do
      post '/api/v1/landing_pages', params: { title: 'Autumn Offer' }.to_json, headers: headers

      form = IntakeForm.find(json['intake_form_id'])
      expect(form.fields.map { |f| f['name'] }).to include('email')
      expect(form.is_active).to be(true)
    end
  end

  describe 'PUT /:id' do
    # SiteRenderer reads the form off the contact block before it falls back to
    # the page, so a page-level change that leaves the blocks alone looks like
    # it worked while the leads keep going to the previous form.
    it 'moves contact blocks that were following the page onto the new form' do
      old_form = IntakeForm.create!(company: company, name: 'Old', fields: [], is_active: true)
      new_form = IntakeForm.create!(company: company, name: 'New', fields: [], is_active: true)
      page.update!(
        intake_form_id: old_form.id,
        blocks: [
          { 'id' => 'b1', 'type' => 'contact', 'order' => 0,
            'content' => { 'intakeFormId' => old_form.id } },
          { 'id' => 'b2', 'type' => 'contact', 'order' => 1, 'content' => {} }
        ]
      )

      put "/api/v1/landing_pages/#{page.id}",
          params: { intake_form_id: new_form.id }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(json['blocks'].map { |b| b['content']['intakeFormId'] }).to all(eq(new_form.id))
    end

    it 'leaves a contact block deliberately bound to some other form alone' do
      other = IntakeForm.create!(company: company, name: 'Other', fields: [], is_active: true)
      new_form = IntakeForm.create!(company: company, name: 'New', fields: [], is_active: true)
      page.update!(
        intake_form_id: nil,
        blocks: [{ 'id' => 'b1', 'type' => 'contact', 'order' => 0,
                   'content' => { 'intakeFormId' => other.id } }]
      )

      put "/api/v1/landing_pages/#{page.id}",
          params: { intake_form_id: new_form.id }.to_json, headers: headers

      expect(json['blocks'].first['content']['intakeFormId']).to eq(other.id)
    end

    it 'keeps the blocks it was sent' do
      put "/api/v1/landing_pages/#{page.id}",
          params: {
            blocks: [
              { id: 'b1', type: 'hero', order: 0,
                content: { title: 'Rewritten', ctaText: 'Get Details', ctaLink: '/inventory' } },
              { id: 'b2', type: 'features', order: 1,
                content: { features: [{ icon: 'x', title: 'F', description: 'd' }] } }
            ]
          }.to_json,
          headers: headers

      expect(json['blocks'].length).to eq(2)
      expect(json['blocks'].first['content']['ctaLink']).to eq('/inventory')
      expect(json['blocks'].last['content']['features'].first['title']).to eq('F')
    end
  end

  describe 'what a preview needs to render' do
    # Without these the builder drew every landing page in default blue with
    # "Contact form not available" where the bound form belongs, which is the
    # one thing an author opens the preview to check.
    it 'returns the embed config and the container theme' do
      get "/api/v1/landing_pages/#{page.id}", headers: headers

      expect(json['inventory_embed_config']).to include(
        'token' => company.reload.public_inventory_token,
        'company_id' => company.id
      )
      expect(json).to have_key('theme')
    end
  end

  describe 'GET /:id/analytics' do
    it 'returns the funnel, engagement, video, sources and timeseries' do
      PageVisit.create!(company_id: company.id, website_page_id: page.id,
                        visitor_token: 'v1', session_token: 's1',
                        max_scroll_depth: 100, converted: true,
                        first_seen_at: 1.hour.ago, last_seen_at: 1.hour.ago)

      get "/api/v1/landing_pages/#{page.id}/analytics", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json['funnel']).to include('visits' => 1, 'conversions' => 1)
      expect(json).to have_key('engagement')
      expect(json).to have_key('video')
      expect(json).to have_key('sources')
      expect(json).to have_key('timeseries')
    end

    it 'returns zeroes for a page with no traffic' do
      get "/api/v1/landing_pages/#{page.id}/analytics", headers: headers

      expect(json['funnel']['visits']).to eq(0)
      expect(json['funnel']['conversion_rate']).to eq(0.0)
    end
  end

  describe 'GET /:id/visitors' do
    let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
    let(:lead) do
      Lead.create!(company: company, source: source, first_name: 'Dana', last_name: 'Reed',
                   status: 'new', email: "d-#{SecureRandom.hex(4)}@example.com")
    end

    # An anonymous row has nothing a salesperson can act on.
    it 'lists identified visitors only' do
      identified = PageVisit.create!(company_id: company.id, website_page_id: page.id,
                                     visitor_token: 'v1', session_token: 's1',
                                     first_seen_at: 1.hour.ago, last_seen_at: 1.hour.ago)
      identified.identify!(lead)
      PageVisit.create!(company_id: company.id, website_page_id: page.id,
                        visitor_token: 'v2', session_token: 's2',
                        first_seen_at: 1.hour.ago, last_seen_at: 1.hour.ago)

      get "/api/v1/landing_pages/#{page.id}/visitors", headers: headers

      expect(json['items'].size).to eq(1)
      expect(json['items'].first['entity_type']).to eq('Lead')
      expect(json['items'].first['entity_id']).to eq(lead.id)
    end
  end

  describe 'module gating' do
    # Behaviour lives in spec/services/module_access_implication_spec.rb. What
    # is worth asserting HERE is only that this controller is wired to the gate
    # at all — a controller that forgets the declaration is the actual failure
    # mode, and it is invisible from the service specs.
    #
    # Deliberately not asserted through an HTTP status: ModuleAccessRequired
    # waves platform and super admins past every gate, and the non-admin roles
    # that would be stopped by it lack websites:read and get refused a step
    # earlier for an unrelated reason. A status assertion would pass for the
    # wrong reason.
    it 'declares the landing pages module requirement' do
      callbacks = Api::V1::LandingPagesController._process_action_callbacks.map(&:filter)
      inline = callbacks.count { |f| f.is_a?(Proc) }

      expect(Api::V1::LandingPagesController.include?(ModuleAccessRequired)).to be(true)
      expect(inline).to be >= 1
    end

    # The Desk's own description promises a landing page, so a Desk tenant must
    # not need a second entitlement to reach this controller.
    it 'treats a Campaign Desk company as entitled' do
      desk = Company.create!(name: "Desk-#{SecureRandom.hex(4)}")
      desk.tenant_module_overrides.create!(module_key: 'marketing.automation', is_enabled: true)

      expect(ModuleAccessService.new(desk).has_module?('marketing.landing_pages')).to be(true)
    end

    it 'treats a company with neither as not entitled' do
      ungated = Company.create!(name: "Ungated-#{SecureRandom.hex(4)}")

      expect(ModuleAccessService.new(ungated).has_module?('marketing.landing_pages')).to be(false)
    end
  end

  describe 'the marketing container stays hidden' do
    it 'does not appear in the websites list' do
      page # provisions the container
      get '/api/v1/websites', headers: headers

      names = JSON.parse(response.body)['items'].map { |w| w['name'] }
      expect(names).not_to include(site.name)
    end

    it 'is not addressable through the websites API' do
      get "/api/v1/websites/#{site.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # An imported design is one customHtml block that names its form by PUBLIC id,
  # because the design's own markup is posted straight to the public endpoint.
  # Only 'contact' blocks were rebound, so on the one kind of page where this
  # picker is the only way to choose a form, choosing did nothing.
  describe 'rebinding an imported design to the chosen form' do
    let(:old_form) do
      company.intake_forms.create!(name: 'Auto-generated', is_active: true, schema: [])
    end
    let(:new_form) do
      company.intake_forms.create!(name: 'Facebook Contact', is_active: true, schema: [])
    end
    let(:imported) do
      site.website_pages.create!(
        title: 'FB', path: '/fb', page_kind: 'landing', intake_form_id: old_form.id,
        blocks: [{ 'id' => 'b1', 'type' => 'customHtml', 'order' => 0,
                   'content' => { 'html' => '<form data-dt-form></form>',
                                  'intakeFormPublicId' => old_form.public_id } }]
      )
    end

    it 'repoints the design at the newly chosen form' do
      patch "/api/v1/landing_pages/#{imported.id}",
            params: { intake_form_id: new_form.id }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(imported.reload.blocks.first['content']['intakeFormPublicId'])
        .to eq(new_form.public_id)
    end

    it 'leaves the design alone when the page has no form' do
      patch "/api/v1/landing_pages/#{imported.id}",
            params: { intake_form_id: nil }.to_json, headers: headers

      expect(imported.reload.blocks.first['content']['intakeFormPublicId'])
        .to eq(old_form.public_id)
    end

    it 'cannot bind a design to another company\'s form' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
      theirs = other.intake_forms.create!(name: 'Theirs', is_active: true, schema: [])

      patch "/api/v1/landing_pages/#{imported.id}",
            params: { intake_form_id: theirs.id }.to_json, headers: headers

      expect(imported.reload.blocks.first['content']['intakeFormPublicId'])
        .not_to eq(theirs.public_id)
    end
  end
end
