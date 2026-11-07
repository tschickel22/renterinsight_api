# frozen_string_literal: true

require 'rails_helper'

# A dealer's own texting registration (E96 phase 4): the dealer fills it in
# and submits, a platform admin sends it to the carriers, and the poller takes
# it to a live number. Twilio is a fake here; nothing real is created.
RSpec.describe 'Texting registration', type: :request do
  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)} Homes") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Ada', last_name: 'Admin', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:complete) do
    {
      brand_type: 'low_volume_standard', preferred_area_code: '720',
      business: { legal_name: 'Summit Park Homes LLC', dba: 'Summit Park Homes', business_type: 'Limited Liability Corporation',
                  ein: '12-3456789', street: '100 Main St', city: 'Denver', state: 'co', zip: '80202', website: 'https://summitpark.example.com' },
      contact: { first_name: 'Ada', last_name: 'Admin', title: 'Owner', email: 'ada@summitpark.example.com', phone: '(303) 555-0101' },
      consent: { sources: %w[website_forms facebook_lead_ads] }
    }
  end

  it 'starts from what we know, lists what is missing, and submits once complete' do
    get '/api/crm/sms_registration', headers: headers
    body = JSON.parse(response.body)
    expect(body['registration']).to include('status' => 'draft', 'editable' => true)
    expect(body['registration']['business']['legal_name']).to eq(company.name)
    expect(body['problems']).to include('EIN (9 digits, as on your IRS letter)')
    expect(body['preview']['samples'].first).to include('Reply STOP')

    post '/api/crm/sms_registration/submit', headers: headers
    expect(response).to have_http_status(:unprocessable_entity)

    patch '/api/crm/sms_registration', headers: headers, params: { registration: complete }.to_json
    body = JSON.parse(response.body)
    expect(body['problems']).to eq([])
    expect(body['registration']['business']).to include('state' => 'CO', 'ein' => '123456789')

    post '/api/crm/sms_registration/submit', headers: headers
    expect(JSON.parse(response.body)['registration']).to include('status' => 'submitted', 'editable' => false)

    patch '/api/crm/sms_registration', headers: headers, params: { registration: { business: { dba: 'Other' } } }.to_json
    expect(response).to have_http_status(:conflict)
  end

  it 'keeps the carrier controls for platform admins' do
    get '/api/admin/sms_registrations', headers: headers
    expect(response.status).to be >= 400
  end

  describe 'with the carriers (fake Twilio)' do
    let(:registration) do
      r = SmsRegistration.prefilled_for(company)
      r.assign_attributes(complete.deep_stringify_keys.except('brand_type').merge(brand_type: 'low_volume_standard'))
      r.update!(status: 'submitted', submitted_at: Time.current)
      r
    end

    let(:made) { [] }
    let(:client) { FakeTwilio.new(made) }

    before do
      allow(TwilioProvisioningService).to receive(:api_base_url).and_return('https://api.example.test')
      allow(TwilioProvisioningService).to receive(:master_credentials).and_return(%w[AC1 token])
    end

    it 'sends it once, even when sent again, and goes live after approval' do
      SmsRegistration::Submitter.new(registration, client: client).call
      expect(registration.reload).to have_attributes(status: 'in_review', customer_profile_sid: 'BU1', trust_product_sid: 'BU2',
                                                     brand_registration_sid: 'BN1', messaging_service_sid: 'MG1')
      SmsRegistration::Submitter.new(registration, client: client).call
      expect(made.count { |m| m == :brand }).to eq(1)

      client.brand_status = 'APPROVED'
      submitted = []
      allow_any_instance_of(SmsRegistration::Submitter).to receive(:rest_post) { |_s, _h, path, attrs| submitted << [path, attrs]; { 'campaign_status' => 'IN_PROGRESS' } }
      SmsRegistration::StatusPoller.new(registration, client: client).call
      expect(registration.reload).to have_attributes(brand_status: 'APPROVED', campaign_status: 'IN_PROGRESS')
      expect(submitted.first[0]).to eq('/v1/Services/MG1/Compliance/Usa2p')
      expect(submitted.first[1]['MessageSamples'].first).to start_with('Summit Park Homes via')

      client.campaign_status = 'VERIFIED'
      SmsRegistration::StatusPoller.new(registration, client: client).call
      expect(registration.reload).to have_attributes(status: 'live', phone_number: '+17205550999', campaign_id: 'CXYZ')
      account = TwilioAccount.find_by(company_id: company.id)
      expect(account.metadata).to include('links_allowed' => true, 'messaging_service_sid' => 'MG1')
    end

    it 'records the reason when the carriers reject the campaign' do
      SmsRegistration::Submitter.new(registration, client: client).call
      client.brand_status = 'APPROVED'
      allow_any_instance_of(SmsRegistration::Submitter).to receive(:rest_post).and_return({ 'campaign_status' => 'IN_PROGRESS' })
      SmsRegistration::StatusPoller.new(registration, client: client).call
      client.campaign_status = 'FAILED'
      SmsRegistration::StatusPoller.new(registration, client: client).call
      expect(registration.reload).to have_attributes(status: 'rejected', rejection_reason: 'Texting not approved: Opt-in unclear.')
      expect(registration.editable?).to be(true)
    end
  end

  # Just enough of twilio-ruby's shape for the submitter and poller.
  class FakeTwilio
    attr_accessor :brand_status, :campaign_status

    def initialize(made)
      @made = made
      @brand_status = 'PENDING'
      @campaign_status = 'IN_PROGRESS'
    end

    def obj(**attrs) = OpenStruct.new(attrs)

    def trusthub = self
    def v1 = self
    def messaging = self

    def customer_profiles(_sid = nil)
      @made << :profile_call
      Builder.new(self, 'BU1')
    end

    def trust_products(_sid = nil) = Builder.new(self, 'BU2')

    def end_users = Builder.new(self, 'IT1')
    def supporting_documents = Builder.new(self, 'RD1')
    def addresses = Builder.new(self, 'AD1')

    def brand_registrations(_sid = nil)
      fake = self
      Class.new do
        define_method(:create) { |**| fake.instance_variable_get(:@made) << :brand; OpenStruct.new(sid: 'BN1', status: 'PENDING') }
        define_method(:fetch) { OpenStruct.new(sid: 'BN1', status: fake.brand_status, failure_reason: nil) }
      end.new
    end

    def services(_sid = nil)
      fake = self
      Class.new do
        define_method(:create) { |**| OpenStruct.new(sid: 'MG1') }
        define_method(:phone_numbers) { Class.new { def create(**) = OpenStruct.new(sid: 'PNX') }.new }
        define_method(:us_app_to_person) do |_sid|
          Class.new do
            define_method(:fetch) do
              OpenStruct.new(campaign_status: fake.campaign_status, campaign_id: 'CXYZ',
                             errors: fake.campaign_status == 'FAILED' ? [{ 'description' => 'Opt-in unclear.' }] : [])
            end
          end.new
        end
      end.new
    end

    def available_phone_numbers(_c)
      Class.new { def local = Class.new { def list(**) = [OpenStruct.new(phone_number: '+17205550999')] }.new }.new
    end

    def incoming_phone_numbers = Class.new { def create(**) = OpenStruct.new(sid: 'PN9', phone_number: '+17205550999') }.new

    class Builder
      def initialize(fake, sid)
        @fake = fake
        @sid = sid
      end

      def create(**) = OpenStruct.new(sid: @sid, status: 'compliant', results: [])
      def update(**) = true
      def customer_profiles_entity_assignments = self
      def customer_profiles_evaluations = self
      def trust_products_entity_assignments = self
      def trust_products_evaluations = self
    end
  end
end
