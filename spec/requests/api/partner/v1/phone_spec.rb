# frozen_string_literal: true

require 'rails_helper'

# What a dealer's 3CX calls through the template from PhoneCalls::ThreeCxTemplate:
# caller lookup, call journaling, and create-lead-for-unknown-caller.
RSpec.describe 'Api::Partner::V1 Phone (3CX)', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:other_company) { Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  let!(:admin) do
    User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", first_name: 'Ada', last_name: 'Admin',
                 password: 'Pass1234!', company_id: company.id, role: 'admin', status: 'active')
  end
  let!(:rep) do
    User.create!(email: "meave-#{SecureRandom.hex(4)}@example.com", first_name: 'Meave', last_name: 'Agbon',
                 password: 'Pass1234!', company_id: company.id, role: 'user', status: 'active')
  end

  let!(:lead) { company.leads.create!(first_name: 'Pat', last_name: 'Buyer', phone: '(352) 555-0101', status: 'new', owner_id: rep.id) }

  def make_key(perms = { 'leads' => %w[read write] })
    ApiKey.new(company_id: company.id, name: '3CX phone system', key: "ri_live_#{SecureRandom.hex(24)}",
               permissions: perms, status: 'active', created_by_user_id: admin.id)
          .tap { |k| k.save!(validate: false) }
  end

  let(:key) { make_key }

  def headers(k = key)
    { 'Authorization' => "Bearer #{k.key}", 'Content-Type' => 'application/json' }
  end

  def report(overrides = {})
    {
      provider: '3cx', call_type: 'Inbound', direction: 'Inbound', number: '+13525550101',
      agent: '105', agent_email: rep.email, agent_name: 'Meave Agbon', duration: '95',
      started_at: '2026-11-06T15:00:00Z', entity_id: '[EntityId]', contact_id: '[Contact::ContactID]'
    }.merge(overrides)
  end

  describe 'lookup' do
    it 'finds the lead by the last ten digits and echoes the number asked' do
      post '/api/partner/v1/phone/lookup', params: { number: '+13525550101' }.to_json, headers: headers
      expect(response).to have_http_status(:ok)
      c = response.parsed_body['contacts'].first
      expect(c['id']).to eq("lead-#{lead.id}")
      expect(c['first_name']).to eq('Pat')
      expect(c['phone']).to eq('+13525550101')
      expect(c['url']).to end_with("/crm/leads/#{lead.id}")
    end

    it 'matches the seven digits 3CX sends when its digits-to-match setting is 7' do
      post '/api/partner/v1/phone/lookup', params: { number: '5550101' }.to_json, headers: headers
      c = response.parsed_body['contacts'].first
      expect(c['id']).to eq("lead-#{lead.id}")
      expect(c['phone']).to eq('5550101')
    end

    it 'logs a call reported with seven digits on the right lead' do
      post '/api/partner/v1/phone/calls', params: report(number: '5550101').to_json, headers: headers
      expect(lead.lead_activities.where(activity_type: 'call').count).to eq(1)
    end

    it 'returns an empty list for an unknown number' do
      get '/api/partner/v1/phone/lookup', params: { number: '+19995550000' }, headers: headers.except('Content-Type')
      expect(response.parsed_body['contacts']).to eq([])
    end

    it 'never reaches another company' do
      other_company.leads.create!(first_name: 'Not', last_name: 'Mine', phone: '3035550199', status: 'new')
      post '/api/partner/v1/phone/lookup', params: { number: '3035550199' }.to_json, headers: headers
      expect(response.parsed_body['contacts']).to eq([])
    end

    it 'refuses a key without leads permission' do
      k = make_key({ 'deals' => %w[read] })
      post '/api/partner/v1/phone/lookup', params: { number: '3525550101' }.to_json, headers: headers(k)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'calls' do
    it 'logs an answered call on the lead, credited to the rep, once' do
      expect do
        post '/api/partner/v1/phone/calls', params: report.to_json, headers: headers
      end.to change { lead.lead_activities.count }.by(1)
      expect(response).to have_http_status(:created)

      act = lead.lead_activities.last
      expect(act.activity_type).to eq('call')
      expect(act.call_direction).to eq('inbound')
      expect(act.call_outcome).to eq('answered')
      expect(act.user_id).to eq(rep.id)
      expect(act.status).to eq('completed')
      expect(act.duration_minutes).to eq(2)
      expect(act.subject).to eq('Incoming call (1 min 35 sec)')

      # 3CX retries: the same report again is recognised, not logged twice.
      expect do
        post '/api/partner/v1/phone/calls', params: report.to_json, headers: headers
      end.not_to(change { lead.lead_activities.count })
      expect(response.parsed_body['duplicate']).to be(true)
    end

    it 'uses the entity id 3CX hands back from the lookup' do
      contact = company.contacts.create!(first_name: 'Sam', last_name: 'Seller', phone: '4075550123')
      post '/api/partner/v1/phone/calls',
           params: report(number: '+14075559999', entity_id: "contact-#{contact.id}").to_json, headers: headers
      expect(contact.contact_activities.where(activity_type: 'call').count).to eq(1)
    end

    it 'keeps an unknown caller in the log without creating a lead' do
      expect do
        post '/api/partner/v1/phone/calls', params: report(number: '+19995550000').to_json, headers: headers
      end.not_to(change { company.leads.count })
      expect(response.parsed_body['matched']).to be(false)
      expect(company.phone_call_logs.unmatched.count).to eq(1)
    end

    it 'falls back to the record owner when the extension matches nobody, and tells them about a missed call' do
      post '/api/partner/v1/phone/calls',
           params: report(call_type: 'Missed', agent_email: '', agent_name: 'Front Desk', duration: '0').to_json,
           headers: headers
      act = lead.lead_activities.last
      expect(act.user_id).to eq(rep.id)
      expect(act.call_outcome).to eq('no_answer')
      expect(act.subject).to eq('Missed call')
      expect(Notification.where(recipient: rep, notification_type: 'missed_call').count).to eq(1)
    end

    it 'reads a .NET TimeSpan duration and an outbound unanswered call' do
      post '/api/partner/v1/phone/calls',
           params: report(call_type: 'Notanswered', duration: '00:00:12', started_at: '2026-11-06T16:00:00Z').to_json,
           headers: headers
      act = lead.lead_activities.last
      expect(act.call_direction).to eq('outbound')
      expect(act.call_outcome).to eq('no_answer')
    end
  end

  describe 'create contact' do
    it 'creates one lead for an unknown caller and returns it in lookup shape' do
      expect do
        post '/api/partner/v1/phone/contacts', params: { number: '+13215550188' }.to_json, headers: headers
      end.to change { company.leads.count }.by(1)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body['contacts'].first['last_name']).to eq('(321) 555-0188')

      post '/api/partner/v1/phone/contacts', params: { number: '+13215550188' }.to_json, headers: headers
      expect(company.leads.count).to eq(2) # Pat plus the one caller, no duplicate
    end
  end

  describe 'template' do
    it 'is well formed XML carrying the key and the three scenarios' do
      xml = PhoneCalls::ThreeCxTemplate.new(base_url: 'https://api.example.com/', api_key: 'ri_live_abc&<x>').to_xml
      doc = Nokogiri::XML(xml) { |c| c.strict }
      expect(doc.errors).to be_empty
      expect(doc.xpath('//Scenario').map { |s| s['Id'] }).to eq(['', 'CreateContactRecord', 'ReportCall'])
      expect(doc.at_xpath("//Parameter[@Name='ApiKey']")['Default']).to eq('ri_live_abc&<x>')
      expect(doc.at_xpath("//Parameter[@Name='Url']")['Default']).to eq('https://api.example.com')
      expect(doc.at_xpath("//Parameter[@Name='CreateContactEnabled']")['Default']).to eq('False')
      expect(doc.at_xpath('//Number')['MaxLength']).to eq('10')
    end
  end
end
