# frozen_string_literal: true

require 'rails_helper'

# Listing syndication partners are platform-level: a platform admin sets one
# up and its feed carries every dealer's published homes. Found while filming:
# a disabled partner still served its feed, one partner row's Account ID was
# sent as the dealer id on every dealer's homes, the feed host defaulted to an
# old brand domain, and any signed-in user could manage partners.
RSpec.describe 'Listing syndication', type: :request do
  let(:platform_company) { create(:company) }
  let(:dealer_a) { create(:company, name: 'Dealer A') }
  let(:dealer_b) { create(:company, name: 'Dealer B') }

  let!(:partner) do
    SyndicationPartner.create!(company: platform_company, name: 'MH Village', partner_type: 'mh_village',
                               format: 'json', listing_types: ['manufactured_home'], account_id: 'PLATFORM-ACCT')
  end

  def publish_home(company)
    vehicle = Vehicle.create!(company: company, year: 2026, make: 'Kabco', model: 'Rubicon',
                              listing_type: 'manufactured_home', vin: "VIN#{SecureRandom.hex(6).upcase}",
                              status: 'available', is_deleted: false, condition: 'new', bedrooms: 3, bathrooms: 2,
                              serial_number: "SN#{SecureRandom.hex(5).upcase}")
    Listing.create!(company: company, vehicle: vehicle, status: 'active', offer_type: 'sale',
                    sale_price: 90_000, published_at: Time.current)
  end

  def user(company, role, email)
    User.create!(email: email, password: 'Password123!', company: company,
                 first_name: 'Test', last_name: 'User', role: role)
  end

  def auth(u)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: u.id, company_id: u.company_id)}" }
  end

  def feed
    get "/public/feeds/#{partner.id}", params: { token: partner.reload.feed_token }
  end

  describe 'GET /public/feeds/:id' do
    before do
      publish_home(dealer_a)
      publish_home(dealer_b)
    end

    it 'serves the feed while the partner is enabled' do
      feed
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['dealers'].size).to eq(2)
    end

    it 'serves nothing once the partner is disabled' do
      partner.update!(active: false)
      feed
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('Kabco')
    end

    it 'sends each dealer its own account number, never the partner row Account ID' do
      partner.set_dealer_account_id!(dealer_a, 'MHV-A-123')
      feed

      by_name = JSON.parse(response.body)['dealers'].index_by { |d| d['dealer_name'] }
      expect(by_name['Dealer A']['dealer_id']).to eq('MHV-A-123')
      expect(by_name['Dealer B']['dealer_id']).to eq(dealer_b.id)
      expect(response.body).not_to include('PLATFORM-ACCT')
    end

    it 'rejects a wrong token' do
      get "/public/feeds/#{partner.id}", params: { token: 'nope' }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'feed address' do
    around do |ex|
      old = ENV.to_h.slice('PUBLIC_FEED_BASE_URL', 'RAILS_API_URL')
      ex.run
    ensure
      %w[PUBLIC_FEED_BASE_URL RAILS_API_URL].each { |k| old.key?(k) ? ENV[k] = old[k] : ENV.delete(k) }
    end

    it 'uses the configured API address, never an old brand domain' do
      ENV.delete('PUBLIC_FEED_BASE_URL')
      ENV['RAILS_API_URL'] = 'https://api.example.test/'
      p = SyndicationPartner.create!(company: platform_company, name: 'RVT', partner_type: 'rvt', format: 'json')

      expect(p.reload.feed_url).to start_with("https://api.example.test/public/feeds/#{p.id}?token=")
      expect(p.feed_url).not_to include('landlordinsight')
      expect(p.public_feed_url).to eq(p.feed_url)
    end
  end

  describe 'platform partner admin API' do
    it 'refuses a dealer user' do
      get '/api/platform/syndication-partners', headers: auth(user(dealer_a, 'company_admin', 'ca@example.com'))
      expect(response).to have_http_status(:forbidden)

      post '/api/platform/syndication-partners',
           params: { partner: { name: 'X', partner_type: 'other', format: 'json' } },
           headers: auth(user(dealer_a, 'user', 'u@example.com'))
      expect(response).to have_http_status(:forbidden)
    end

    it 'lets a platform admin see every partner and switch one off' do
      admin = user(dealer_b, 'platform_admin', 'pa@example.com')
      get '/api/platform/syndication-partners', headers: auth(admin)
      expect(response.parsed_body['partners'].map { |p| p['id'] }).to eq([partner.id.to_s])

      patch "/api/platform/syndication-partners/#{partner.id}/toggle", headers: auth(admin)
      expect(partner.reload.active).to be(false)
    end
  end

  describe 'dealer Listing Partners tab' do
    it 'lists platform partners with this dealer\'s own account number and no feed secrets' do
      partner.set_dealer_account_id!(dealer_a, 'MHV-A-123')
      partner.set_dealer_account_id!(dealer_b, 'MHV-B-999')

      get '/api/v1/listing_partners', headers: auth(user(dealer_a, 'company_admin', 'ca@example.com'))
      expect(response).to have_http_status(:ok)
      row = response.parsed_body['partners'].first
      expect(row['dealerAccountId']).to eq('MHV-A-123')
      expect(response.body).not_to include('MHV-B-999', partner.feed_token, 'PLATFORM-ACCT')
      expect(response.parsed_body['canEdit']).to be(true)
    end

    it 'lets a company admin save and clear their own account number only' do
      admin = user(dealer_a, 'company_admin', 'ca@example.com')
      patch "/api/v1/listing_partners/#{partner.id}", params: { dealer_account_id: ' MHV-A-1 ' }, headers: auth(admin)
      expect(response).to have_http_status(:ok)
      expect(partner.dealer_account_id_for(dealer_a)).to eq('MHV-A-1')
      expect(SyndicationPartner.new(id: partner.id).dealer_account_id_for(dealer_b)).to be_nil
      expect(partner.reload.account_id).to eq('PLATFORM-ACCT')

      patch "/api/v1/listing_partners/#{partner.id}", params: { dealer_account_id: '' }, headers: auth(admin)
      expect(SyndicationPartner.find(partner.id).dealer_account_id_for(dealer_a)).to be_nil
    end

    it 'does not let a non-admin change it' do
      u = user(dealer_a, 'user', 'u@example.com')
      patch "/api/v1/listing_partners/#{partner.id}", params: { dealer_account_id: 'X' }, headers: auth(u)
      expect(response).to have_http_status(:forbidden)
      expect(partner.dealer_account_id_for(dealer_a)).to be_nil
    end
  end
end
