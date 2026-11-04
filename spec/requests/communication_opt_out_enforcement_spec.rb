# frozen_string_literal: true

require 'rails_helper'

# Every endpoint a person sends a text or email through. The platform endpoint
# and the leads endpoint used to send to anyone, and the contact endpoint only
# read its own columns, so a STOP text was honored only by the carrier.
RSpec.describe 'Opt-outs on typed sends', type: :request do
  let(:company) { Company.create!(name: "Opt #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }
  let(:contact) do
    Contact.create!(company: company, first_name: 'Pat', last_name: 'Smith', phone: '(303) 555-0187',
                    email: "pat-#{SecureRandom.hex(3)}@example.com")
  end
  let(:lead) do
    Lead.new(company: company, first_name: 'Dana', last_name: 'Whitfield', phone: '720-555-0142',
             email: "dana-#{SecureRandom.hex(3)}@example.com").tap { |l| l.save!(validate: false) }
  end

  def stop(recipient, channel = 'sms')
    CommunicationPreference.find_or_create_for(recipient: recipient, channel: channel).opt_out!('SMS STOP keyword received')
  end

  def code
    JSON.parse(response.body)['code']
  end

  before do
    allow(TwilioSmsService).to receive(:send).and_raise('a refused text must not reach Twilio')
    allow(Net::HTTP).to receive(:start).and_raise('a refused send must not reach a provider')
  end

  describe 'texts' do
    it 'refuses on the platform endpoint after a STOP on a lead' do
      stop(lead)
      post '/api/platform/communications/sms',
           params: { entity_type: 'Lead', entity_id: lead.id, to: lead.phone, message: 'hello' }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(code).to eq('opted_out_sms')
    end

    it 'refuses on the platform endpoint when only the contact columns say so' do
      contact.update!(opt_out_sms: true)
      post '/api/platform/communications/sms',
           params: { entity_type: 'Contact', entity_id: contact.id, to: contact.phone, message: 'hello' }, headers: headers

      expect(code).to eq('opted_out_sms')
    end

    it 'refuses on the leads endpoint the Workqueue uses' do
      stop(lead)
      post '/api/crm/communications/sms', params: { lead_id: lead.id, body: 'hello' }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(code).to eq('opted_out_sms')
    end

    it 'refuses on the contact endpoint after a STOP, which it used to miss' do
      stop(contact)
      post "/api/v1/contacts/#{contact.id}/communications/sms", params: { body: 'hello' }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(code).to eq('opted_out_sms')
    end

    it 'refuses when the same number opted out on a different record' do
      other = Contact.create!(company: company, first_name: 'Same', last_name: 'Person', phone: '+1 720 555 0142',
                              email: "same-#{SecureRandom.hex(3)}@example.com")
      stop(other)
      post '/api/platform/communications/sms',
           params: { entity_type: 'Lead', entity_id: lead.id, to: lead.phone, message: 'hello' }, headers: headers

      expect(code).to eq('opted_out_sms')
    end

    it "is not fooled by another company's opt-out on the same number" do
      elsewhere = Company.create!(name: "Else #{SecureRandom.hex(4)}", industry: 'manufactured_housing')
      other = Contact.create!(company: elsewhere, first_name: 'No', last_name: 'Relation', phone: lead.phone,
                              email: "else-#{SecureRandom.hex(3)}@example.com")
      stop(other)

      expect(CommunicationOptOut.check(channel: 'sms', company: company, record: lead, address: lead.phone)).not_to be_opted_out
    end

    it 'cannot be overridden the way an email can' do
      stop(lead)
      post '/api/platform/communications/sms',
           params: { entity_type: 'Lead', entity_id: lead.id, to: lead.phone, message: 'hello', about_purchase: '1' }, headers: headers

      expect(code).to eq('opted_out_sms')
    end

    it 'lets a text through to someone who has opted back in' do
      stop(lead)
      CommunicationPreference.find_or_create_for(recipient: lead, channel: 'sms').opt_in!

      expect(CommunicationOptOut.check(channel: 'sms', company: company, record: lead, address: lead.phone)).not_to be_opted_out
    end
  end

  describe 'email' do
    it 'asks for confirmation on the platform endpoint' do
      stop(lead, 'email')
      post '/api/platform/communications/email',
           params: { entity_type: 'Lead', entity_id: lead.id, to: lead.email, subject: 'Hi', body: '<p>Hi</p>' }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(code).to eq('opted_out_email')
      expect(Communication.where(communicable: lead)).to be_empty
    end

    it 'gets past the refusal once the sender confirms it is about the purchase' do
      contact.update!(opt_out_email: true)
      post '/api/platform/communications/email',
           params: { entity_type: 'Contact', entity_id: contact.id, to: contact.email, subject: 'Hi', body: '<p>Hi</p>', about_purchase: '1' },
           headers: headers

      expect(code).not_to eq('opted_out_email')
    end

    it 'asks on the leads endpoint and the contact endpoint' do
      stop(lead, 'email')
      contact.update!(opt_out_email: true)

      post '/api/crm/communications/email', params: { lead_id: lead.id, subject: 'Hi', body: 'Hi' }, headers: headers
      expect(code).to eq('opted_out_email')

      post "/api/v1/contacts/#{contact.id}/communications/email", params: { subject: 'Hi', body: 'Hi' }, headers: headers
      expect(code).to eq('opted_out_email')
    end

    it 'leaves someone alone who only opted out of texts' do
      stop(lead, 'sms')

      expect(CommunicationOptOut.check(channel: 'email', company: company, record: lead, address: lead.email)).not_to be_opted_out
    end
  end
end
