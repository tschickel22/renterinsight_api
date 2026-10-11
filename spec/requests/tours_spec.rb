# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Product tours', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }

  def make_user(role: nil)
    User.create!(email: "tour-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Tour', last_name: 'User', role: role)
  end

  def auth(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  let(:user) { make_user }
  let!(:tour) do
    Tour.create!(key: "t-#{SecureRandom.hex(3)}", name: 'Welcome to {{brand}}', trigger_type: 'manual').tap do |t|
      t.steps.create!(position: 1, title: 'One', content: 'Hello from {{brand}}', selector: '[data-tour="a"]')
      t.steps.create!(position: 2, title: 'Two', content: 'Second', selector: '[data-tour="b"]')
    end
  end

  def tours_json(user, **params)
    get '/api/v1/tours', params: params, headers: auth(user)
    JSON.parse(response.body)
  end

  describe 'pausing' do
    before { PlatformSetting.tours_paused = true }
    after  { PlatformSetting.tours_paused = false }

    it 'serves no tours to users while paused' do
      expect(tours_json(user)['tours']).to eq([])
    end

    it 'still serves tours to platform admins so they can test and fix them' do
      body = tours_json(make_user(role: 'platform_admin'))

      expect(body['tours'].map { |t| t['id'] }).to include(tour.id)
      expect(body['tours_paused']).to eq(true)
    end
  end

  describe 'brand copy' do
    it 'fills in {{brand}} when serving a tour' do
      get "/api/v1/tours/#{tour.id}", headers: auth(user)
      body = JSON.parse(response.body)

      expect(body['name']).to eq("Welcome to #{Brand.current.name}")
      expect(body['steps'].first['content']).to eq("Hello from #{Brand.current.name}")
    end

    it 'leaves the token in place for an admin editing the tour' do
      get "/api/v1/tours/#{tour.id}", params: { raw: 'true' }, headers: auth(make_user(role: 'platform_admin'))

      expect(JSON.parse(response.body)['name']).to eq('Welcome to {{brand}}')
    end

    it "fills in dealer words from the company being viewed" do
      other = create(:company)
      allow_any_instance_of(Company).to receive(:resolved_labels) { |c| c.id == other.id ? { 'deals' => 'Opportunities' } : {} }
      tour.update!(name: 'Open {{label:deals|Sales Deals}}')
      admin = make_user(role: 'platform_admin')

      get "/api/v1/tours/#{tour.id}", headers: auth(admin).merge('X-Company-ID' => other.id.to_s)
      expect(JSON.parse(response.body)['name']).to eq('Open Opportunities')
    end

    it 'ignores raw for everyone else' do
      get "/api/v1/tours/#{tour.id}", params: { raw: 'true' }, headers: auth(user)

      expect(JSON.parse(response.body)['name']).to eq("Welcome to #{Brand.current.name}")
    end
  end

  describe 'dismissing' do
    it 'is not a completion: the tour stays listed, flagged as dismissed' do
      post "/api/v1/tours/#{tour.id}/dismiss", headers: auth(user)
      listed = tours_json(user)['tours'].find { |t| t['id'] == tour.id }

      expect(listed).to include('dismissed' => true, 'completed' => false)
      expect(UserTourCompletion.find_by(user: user, tour: tour).completed_at).to be_nil
    end
  end

  describe 'step progress' do
    it 'records the first step and completes the tour once every step is done' do
      post "/api/v1/tours/#{tour.id}/step_complete", params: { step_position: 1 }, headers: auth(user)
      expect(JSON.parse(response.body)).to include('steps_completed' => 1, 'completed_at' => nil)

      post "/api/v1/tours/#{tour.id}/step_complete", params: { step_position: 2 }, headers: auth(user)
      expect(JSON.parse(response.body)['completed_at']).to be_present
    end
  end

  describe 'check results' do
    it 'records what a check found and marks the tour failing when a step is missing' do
      admin = make_user(role: 'platform_admin')
      post "/api/v1/tours/#{tour.id}/check_results",
           params: { results: [{ position: 1, status: 'found' }, { position: 2, status: 'missing' }] }, headers: auth(admin), as: :json

      expect(JSON.parse(response.body)['check_status']).to eq('failing')
      expect(tour.steps.find_by(position: 2).check_status).to eq('missing')
    end

    it 'is for platform admins only' do
      post "/api/v1/tours/#{tour.id}/check_results", params: { results: [] }, headers: auth(user), as: :json
      expect(response).to have_http_status(:forbidden)
    end

    context 'the nightly checker account' do
      before { ENV['GUIDE_CHECK_EMAIL'] = user.email.upcase }
      after  { ENV.delete('GUIDE_CHECK_EMAIL') }

      it 'can list tours while paused and record results' do
        PlatformSetting.tours_paused = true
        get '/api/v1/tours/for_check', headers: auth(user)
        expect(JSON.parse(response.body)['tours'].map { |t| t['id'] }).to include(tour.id)

        post "/api/v1/tours/#{tour.id}/check_results", params: { results: [{ position: 1, status: 'found' }] }, headers: auth(user), as: :json
        expect(response).to have_http_status(:ok)
      ensure
        PlatformSetting.tours_paused = false
      end

      it 'is not counted as product usage' do
        post '/api/v1/guide/events', params: { events: [{ kind: 'page', feature: 'page:/deals' }] }, headers: auth(user), as: :json
        expect(GuideEvent.count).to eq(0)
      end
    end

    it 'does not let other users list tours for checking' do
      get '/api/v1/tours/for_check', headers: auth(user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'trigger types' do
    it 'maps the names older recorders sent onto auto_on_first_visit' do
      %w[first_visit auto_on_route first_login].each do |legacy|
        t = Tour.create!(key: "legacy-#{legacy}", name: legacy, trigger_type: legacy, trigger_route: '/deals')

        expect(t.trigger_type).to eq('auto_on_first_visit')
      end
    end
  end
end
