# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::CompanyDomains', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  describe 'POST /api/v1/company-domains' do
    let(:preflight) { Dns::PreFlight::Result.new(current_addresses: [], points_at_us: false, issues: []) }

    before do
      allow(CloudflareSaasService).to receive(:configured?).and_return(true)
      allow(Dns::PreFlight).to receive(:for).and_return(preflight)
    end

    # www.easyhomesource.com was created on HTTP validation while it still served the
    # dealer's Vercel site, so the certificate could not issue until they switched, and
    # the site would have had none in between.
    it 'uses TXT validation and keeps the certificate records when a site is live elsewhere' do
      preflight.current_target = 'cname.vercel-dns.com'
      service = instance_double(CloudflareSaasService)
      allow(CloudflareSaasService).to receive(:new).and_return(service)
      allow(service).to receive(:cname_target).and_return('connect.mydealertide.com')
      allow(service).to receive(:create_worker_route)
      expect(service).to receive(:add_custom_hostname)
        .with('www.live.example', ssl_method: 'txt').and_return({})
      allow(service).to receive(:parse_custom_hostname_response).and_return(
        custom_hostname_id: 'cf-live', verification_status: 'pending', ssl_status: 'pending_validation',
        verification_records: [{ 'type' => 'TXT', 'name' => '_cf-custom-hostname.www.live.example',
                                 'value' => 'own-1' }],
        certificate_records: [{ 'type' => 'TXT', 'name' => '_acme-challenge.www.live.example',
                                'value' => 'cert-1', 'kind' => 'certificate' }]
      )

      post '/api/v1/company-domains',
           params: { hostname: 'www.live.example', purpose: 'web' }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:created)
      records = JSON.parse(response.body)['domain']['web_dns_records']
      expect(records.map { |r| r['value'] }).to eq(%w[own-1 cert-1 connect.mydealertide.com])
      expect(records.last['switch_last']).to be true
    end

    # Cloudflare's SSL vocabulary is far wider than the four values the model used to
    # allow. A successful provisioning failed on our own validation, leaving the hostname
    # live in Cloudflare and a half-written row here, so the retry reported the domain as
    # already registered and there was no way forward.
    it 'accepts the status values Cloudflare actually returns' do
      service = instance_double(CloudflareSaasService)
      allow(CloudflareSaasService).to receive(:new).and_return(service)
      allow(service).to receive(:add_custom_hostname).and_return({})
      allow(service).to receive(:cname_target).and_return('connect.mydealertide.com')
      allow(service).to receive(:create_worker_route)
      allow(service).to receive(:parse_custom_hostname_response).and_return(
        custom_hostname_id: 'cf-abc123',
        verification_status: 'pending_validation',
        verification_records: [],
        ssl_status: 'initializing',
        cname_target: 'connect.mydealertide.com'
      )

      post '/api/v1/company-domains',
           params: { hostname: 'www.dealer.example', purpose: 'web' }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:created)
      domain = CompanyDomain.find_by(hostname: 'www.dealer.example')
      expect(domain.cloudflare_custom_hostname_id).to eq('cf-abc123')
      expect(domain.ssl_status).to eq('initializing')
    end

    it 'leaves nothing behind when the write fails after provisioning' do
      service = instance_double(CloudflareSaasService)
      allow(CloudflareSaasService).to receive(:new).and_return(service)
      allow(service).to receive(:add_custom_hostname).and_return({})
      allow(service).to receive(:cname_target).and_return('connect.mydealertide.com')
      allow(service).to receive(:create_worker_route)
      allow(service).to receive(:parse_custom_hostname_response).and_return(
        custom_hostname_id: 'cf-orphan', verification_status: 'pending',
        verification_records: [], ssl_status: 'pending', cname_target: nil
      )
      allow_any_instance_of(CompanyDomain).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(CompanyDomain.new))
      # The hostname is live in Cloudflare at this point, so it has to be released or the
      # tenant can never add that domain again.
      expect(service).to receive(:delete_custom_hostname).with('cf-orphan')

      post '/api/v1/company-domains',
           params: { hostname: 'www.doomed.example', purpose: 'web' }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(CompanyDomain.find_by(hostname: 'www.doomed.example')).to be_nil
    end
  end

  describe 'POST /api/v1/company-domains/:id/check-dns' do
    let!(:domain) do
      company.company_domains.create!(
        hostname: 'dealer.example', web_enabled: true,
        cname_target: 'connect.mydealertide.com',
        verification_records: [
          { 'type' => 'TXT', 'name' => '_cf-custom-hostname.dealer.example',
            'value' => 'abc-123-token', 'ttl' => 3600 }
        ]
      )
    end

    def stub_txt(values)
      allow(Dns::Lookup).to receive(:txt).and_return(values)
      allow(Dns::Lookup).to receive(:cname).and_return(['connect.mydealertide.com'])
    end

    # This used to look only for a CNAME on the hostname itself, so a correctly published
    # TXT ownership record reported "CNAME record not found" — telling a tenant who had
    # done everything right that they had done nothing.
    it 'finds a published TXT ownership record' do
      stub_txt(['abc-123-token'])

      post "/api/v1/company-domains/#{domain.id}/check-dns", headers: auth_headers

      body = JSON.parse(response.body)
      expect(body['configured']).to be true
      expect(body['records'].first['found']).to be true
    end

    # Measured on a real hostname: with the CNAME live and resolving to Cloudflare, HTTP
    # returned 409 (custom hostname not active) and no certificate issued until the
    # ownership record was published. A CNAME alone does not bootstrap ownership.
    it 'is not satisfied by the routing CNAME alone' do
      allow(Dns::Lookup).to receive(:txt).and_return([])
      allow(Dns::Lookup).to receive(:cname).and_return(['connect.mydealertide.com'])

      post "/api/v1/company-domains/#{domain.id}/check-dns", headers: auth_headers

      expect(JSON.parse(response.body)['configured']).to be false
    end

    it 'is not satisfied when the routing CNAME is missing' do
      allow(Dns::Lookup).to receive(:txt).and_return(['abc-123-token'])
      allow(Dns::Lookup).to receive(:cname).and_return([])

      post "/api/v1/company-domains/#{domain.id}/check-dns", headers: auth_headers

      expect(JSON.parse(response.body)['configured']).to be false
    end

    it 'tells the tenant to point the domain at us, which Cloudflare never mentions' do
      stub_txt(['abc-123-token'])

      post "/api/v1/company-domains/#{domain.id}/check-dns", headers: auth_headers

      cname = JSON.parse(response.body)['records'].find { |r| r['type'] == 'CNAME' }
      expect(cname['expected']).to eq('connect.mydealertide.com')
    end

    # A tenant with the TXT live everywhere and the CNAME still on their old host was told
    # "Not all records are visible yet", which read as the TXT having failed.
    it 'names what was found and what the CNAME points at now' do
      allow(Dns::Lookup).to receive(:txt).and_return(['abc-123-token'])
      allow(Dns::Lookup).to receive(:cname).and_return(['cname.vercel-dns.com.'])

      post "/api/v1/company-domains/#{domain.id}/check-dns", headers: auth_headers

      message = JSON.parse(response.body)['message']
      expect(message).to include('Found: TXT _cf-custom-hostname.dealer.example')
      expect(message).to include('CNAME dealer.example points at cname.vercel-dns.com. ' \
                                 'Change it to connect.mydealertide.com.')
      expect(message).not_to match(/propagate|up to an hour/)
    end

    it 'tells a tenant on TXT validation to leave the CNAME until the certificate issues' do
      domain.update!(verification_records: domain.verification_records + [
        { 'type' => 'TXT', 'name' => '_acme-challenge.dealer.example', 'value' => 'cert-1',
          'kind' => 'certificate' }
      ])
      allow(Dns::Lookup).to receive(:txt).and_return(%w[abc-123-token cert-1])
      allow(Dns::Lookup).to receive(:cname).and_return(['cname.vercel-dns.com.'])

      post "/api/v1/company-domains/#{domain.id}/check-dns", headers: auth_headers

      message = JSON.parse(response.body)['message']
      expect(message).to include('Found: TXT _cf-custom-hostname.dealer.example, TXT _acme-challenge.dealer.example')
      expect(message).to include('which keeps your current site up')
      expect(message).to include('once the certificate shows as issued')
    end

    it 'says a record is not published yet when nothing answers for it' do
      allow(Dns::Lookup).to receive(:txt).and_return([])
      allow(Dns::Lookup).to receive(:cname).and_return([])

      post "/api/v1/company-domains/#{domain.id}/check-dns", headers: auth_headers

      message = JSON.parse(response.body)['message']
      expect(message).to include('TXT _cf-custom-hostname.dealer.example is not published yet')
      expect(message).not_to include('Found:')
    end

    it 'says so plainly when nothing has been issued yet' do
      domain.update!(verification_records: [], cname_target: nil)

      post "/api/v1/company-domains/#{domain.id}/check-dns", headers: auth_headers

      expect(JSON.parse(response.body)['message']).to match(/no dns records issued/i)
    end
  end

  describe 'GET /api/v1/company-domains/hostname-advice' do
    it 'includes the pre-flight for the hostname being added' do
      allow(CloudflareSaasService).to receive(:configured?).and_return(false)
      allow(Dns::PreFlight).to receive(:for).with('www.dealer.example', our_target: nil).and_return(
        Dns::PreFlight::Result.new(hostname: 'www.dealer.example', current_target: 'cname.vercel-dns.com',
                                   current_addresses: [], points_at_us: false, caa_issuers: [],
                                   caa_missing: [], issues: [])
      )

      get '/api/v1/company-domains/hostname-advice', params: { hostname: 'www.dealer.example' },
                                                     headers: auth_headers.except('Content-Type')

      preflight = JSON.parse(response.body)['preflight']
      expect(preflight['live_elsewhere']).to be true
      expect(preflight['ssl_method']).to eq('txt')
    end
  end

  describe 'assigning a website to a domain' do
    let(:location) { company.locations.create!(name: 'Showroom') }
    let!(:site) do
      Website.create!(company_id: company.id, location_id: location.id, name: 'Dealer Site',
                      slug: "s-#{SecureRandom.hex(4)}", status: 'published')
    end
    let!(:domain) { company.company_domains.create!(hostname: 'dealer.example', web_enabled: true) }

    it 'offers this company\'s websites to choose from' do
      get '/api/v1/company-domains', headers: auth_headers

      names = JSON.parse(response.body)['available_websites'].map { |w| w['id'] }
      expect(names).to include(site.id)
    end

    it 'assigns the website' do
      patch "/api/v1/company-domains/#{domain.id}",
            params: { website_id: site.id }.to_json, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(domain.reload.website_id).to eq(site.id)
    end

    it 'allows clearing the assignment' do
      domain.update!(website_id: site.id)

      patch "/api/v1/company-domains/#{domain.id}",
            params: { website_id: '' }.to_json, headers: auth_headers

      expect(domain.reload.website_id).to be_nil
    end

    # Tenant isolation: a website id is attacker-controlled input, so it is looked up
    # scoped to the company rather than taken on trust.
    it 'refuses a website belonging to another company' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      foreign = Website.create!(company_id: other.id, location_id: other.locations.create!(name: 'L').id,
                                name: 'Theirs', slug: "o-#{SecureRandom.hex(4)}", status: 'published')

      patch "/api/v1/company-domains/#{domain.id}",
            params: { website_id: foreign.id }.to_json, headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(domain.reload.website_id).to be_nil
    end

    it 'does not offer another company\'s websites' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      foreign = Website.create!(company_id: other.id, location_id: other.locations.create!(name: 'L').id,
                                name: 'Theirs', slug: "o-#{SecureRandom.hex(4)}", status: 'published')

      get '/api/v1/company-domains', headers: auth_headers

      ids = JSON.parse(response.body)['available_websites'].map { |w| w['id'] }
      expect(ids).not_to include(foreign.id)
    end
  end

  describe 'DELETE /api/v1/company-domains/:id' do
    # One record serves the website and email independently. Destroying it outright took a
    # verified sending domain with it, which happened for real on staging: removing what
    # looked like a duplicate row from the website list deleted a domain that had been
    # through DNS verification. Re-verifying means republishing DNS, so this is expensive to
    # lose by accident.
    context 'when the domain is also verified for sending email' do
      let!(:domain) do
        company.company_domains.create!(
          hostname: 'dealer.example', web_enabled: true, email_enabled: true,
          email_verified_at: Time.current, ses_dkim_tokens: %w[a b c],
          ses_identity_status: 'SUCCESS'
        )
      end

      it 'keeps the record rather than destroying it' do
        delete "/api/v1/company-domains/#{domain.id}", headers: auth_headers

        expect(response).to have_http_status(:ok)
        expect(CompanyDomain.find_by(id: domain.id)).to be_present
      end

      it 'removes only the website role' do
        delete "/api/v1/company-domains/#{domain.id}", headers: auth_headers

        expect(domain.reload.web_enabled).to be false
        expect(domain.active).to be false
      end

      it 'leaves email sending verified and intact' do
        delete "/api/v1/company-domains/#{domain.id}", headers: auth_headers

        expect(domain.reload.email_enabled).to be true
        expect(domain.email_verified?).to be true
        expect(domain.ses_dkim_tokens).to eq(%w[a b c])
      end

      it 'says so, so the outcome is not a surprise' do
        delete "/api/v1/company-domains/#{domain.id}", headers: auth_headers

        expect(JSON.parse(response.body)['message']).to match(/still verified for sending/i)
      end
    end

    context 'when the domain is only used for the website' do
      let!(:domain) do
        company.company_domains.create!(hostname: 'web-only.example', web_enabled: true)
      end

      it 'destroys the record' do
        delete "/api/v1/company-domains/#{domain.id}", headers: auth_headers

        expect(response).to have_http_status(:ok)
        expect(CompanyDomain.find_by(id: domain.id)).to be_nil
      end
    end

    it 'will not touch another company\'s domain' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      foreign = other.company_domains.create!(hostname: 'not-yours.example', web_enabled: true)

      delete "/api/v1/company-domains/#{foreign.id}", headers: auth_headers

      expect(response).to have_http_status(:not_found)
      expect(CompanyDomain.find_by(id: foreign.id)).to be_present
    end
  end
end
