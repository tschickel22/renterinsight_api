# frozen_string_literal: true

require 'rails_helper'

# Inbound SMS routing keys off the contact's phone number, which is NOT unique
# across tenants — two dealerships can hold the same customer. Every lookup in
# the webhook must therefore be scoped to the company that owns the number the
# message was sent TO, or a reply lands in the wrong tenant.
RSpec.describe 'Webhooks::Twilio inbound tenant scoping', type: :request do
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }

  let(:company_a) { Company.create!(name: "CoA-#{SecureRandom.hex(4)}") }
  let(:company_b) { Company.create!(name: "CoB-#{SecureRandom.hex(4)}") }

  let(:rep_a) do
    User.create!(email: "rep-a-#{SecureRandom.hex(4)}@example.com", first_name: 'Rep', last_name: 'A',
                 password: 'Pass1234!', company_id: company_a.id, role: 'company_admin',
                 phone: '+15550000001')
  end
  let(:rep_b) do
    User.create!(email: "rep-b-#{SecureRandom.hex(4)}@example.com", first_name: 'Rep', last_name: 'B',
                 password: 'Pass1234!', company_id: company_b.id, role: 'company_admin',
                 phone: '+15550000002')
  end

  # The same customer, known to both dealerships.
  let(:shared_phone) { '+13035709810' }
  let(:lead_a) do
    Lead.create!(company: company_a, source: source, first_name: 'Shared', last_name: 'CustomerA',
                 email: "a-#{SecureRandom.hex(4)}@example.com", phone: shared_phone)
  end
  let(:lead_b) do
    Lead.create!(company: company_b, source: source, first_name: 'Shared', last_name: 'CustomerB',
                 email: "b-#{SecureRandom.hex(4)}@example.com", phone: shared_phone)
  end

  # Only company A has provisioned this number; the reply comes back to it.
  let(:number_a) { '+15551110000' }
  let!(:twilio_account_a) do
    TwilioAccount.create!(company: company_a, phone_number: number_a,
                          phone_number_sid: "PN#{SecureRandom.hex(8)}", status: 'active')
  end

  before do
    # Blank auth token => signature verification is skipped (see #verify_twilio_signature).
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TWILIO_AUTH_TOKEN').and_return(nil)
    allow(ENV).to receive(:[]).with('TWILIO_PHONE_NUMBER').and_return(nil)
    allow(TwilioSmsService).to receive(:send_via_master).and_return({ success: true, message_sid: 'SM_test' })
  end

  def outbound_sms(company:, lead:, sender:, from:, sent_at:)
    Communication.create!(
      company_id: company.id, communicable: lead, channel: 'sms', direction: 'outbound',
      from_address: from, to_address: shared_phone, body: 'Hello from us', status: 'sent',
      sent_at: sent_at, created_at: sent_at,
      metadata: { 'sender_user_id' => sender.id, 'assigned_user_id' => sender.id }
    )
  end

  describe 'POST /webhooks/twilio/sms/inbound' do
    # Company B texted the customer MORE RECENTLY than company A. Before the fix the
    # unscoped "most recent outbound to this number" match picked B's message even
    # though the reply arrived on A's number.
    let!(:outbound_a) do
      outbound_sms(company: company_a, lead: lead_a, sender: rep_a, from: number_a, sent_at: 2.hours.ago)
    end
    let!(:outbound_b) do
      outbound_sms(company: company_b, lead: lead_b, sender: rep_b, from: '+15552220000', sent_at: 5.minutes.ago)
    end

    let(:params) do
      { 'From' => shared_phone, 'To' => number_a, 'Body' => 'Yes I am still interested',
        'MessageSid' => "SM#{SecureRandom.hex(8)}" }
    end

    it 'attributes the reply to the company that owns the receiving number' do
      expect { post '/webhooks/twilio/sms/inbound', params: params }
        .to change { Communication.where(direction: 'inbound').count }.by(1)

      inbound = Communication.where(direction: 'inbound').order(:created_at).last

      expect(inbound.company_id).to eq(company_a.id)
      expect(inbound.communicable).to eq(lead_a)
      expect(inbound.metadata['matched_outbound_id']).to eq(outbound_a.id)
    end

    it 'does not leak the reply to the other tenant' do
      post '/webhooks/twilio/sms/inbound', params: params

      inbound = Communication.where(direction: 'inbound').order(:created_at).last

      expect(inbound.company_id).not_to eq(company_b.id)
      expect(inbound.communicable).not_to eq(lead_b)
      expect(inbound.metadata['matched_outbound_id']).not_to eq(outbound_b.id)
    end

    it "forwards the customer's message to the owning company's rep, not the other tenant's" do
      post '/webhooks/twilio/sms/inbound', params: params

      expect(TwilioSmsService).to have_received(:send_via_master)
        .with(hash_including(to: rep_a.phone))
      expect(TwilioSmsService).not_to have_received(:send_via_master)
        .with(hash_including(to: rep_b.phone))
    end

    it 'mints the reply token against the owning company and its rep' do
      post '/webhooks/twilio/sms/inbound', params: params

      token = SmsReplyToken.order(:created_at).last
      expect(token.company_id).to eq(company_a.id)
      expect(token.sender_user_id).to eq(rep_a.id)
      expect(token.communication_id).to eq(outbound_a.id)
    end
  end

  describe 'STOP keyword' do
    # Company B's contact is created FIRST on purpose: the old unscoped lookup took
    # `.first`, so B would win. Creating A first would let this pass either way.
    let!(:contact_b) do
      Contact.create!(company: company_b, first_name: 'Shared', last_name: 'ContactB',
                      email: "cb-#{SecureRandom.hex(4)}@example.com", phone: shared_phone)
    end
    let!(:contact_a) do
      Contact.create!(company: company_a, first_name: 'Shared', last_name: 'ContactA',
                      email: "ca-#{SecureRandom.hex(4)}@example.com", phone: shared_phone)
    end

    it "opts out the receiving company's contact only" do
      post '/webhooks/twilio/sms/inbound',
           params: { 'From' => shared_phone, 'To' => number_a, 'Body' => 'STOP',
                     'MessageSid' => "SM#{SecureRandom.hex(8)}" }

      pref_a = CommunicationPreference.find_by(recipient: contact_a, channel: 'sms')
      pref_b = CommunicationPreference.find_by(recipient: contact_b, channel: 'sms')

      expect(pref_a&.opted_in).to eq(false)
      expect(pref_b&.opted_in).not_to eq(false)
    end
  end

  # Sending from the shared number is supported; replying to it is not, and
  # cannot be — the number identifies no tenant.
  describe 'the shared platform number' do
    let(:platform_number) { '+17205752095' }

    before do
      allow(PlatformSetting).to receive(:communications).and_return(
        { 'sms' => { 'fromNumber' => '17205752095' } }
      )
    end

    let(:params) do
      { 'From' => shared_phone, 'To' => platform_number, 'Body' => 'Still interested',
        'MessageSid' => "SM#{SecureRandom.hex(8)}" }
    end

    # The stored value has no leading +, Twilio's To always does, and the old
    # comparison was a raw ==. It also read ENV['TWILIO_PHONE_NUMBER'], which is
    # a different setting entirely and unset in production, so this branch was
    # never recognised as the platform number at all.
    it 'recognises the number even though settings store it without a plus' do
      post '/webhooks/twilio/sms/inbound', params: params

      expect(response).to have_http_status(:ok)
    end

    # The reply cannot be attributed, and guessing is worse than dropping it:
    # phone numbers are not unique across tenants, so the old across-all-tenants
    # match handed one company's customer to another company's rep.
    it 'does not attribute the reply to whichever tenant texted most recently' do
      outbound_sms(company: company_b, lead: lead_b, sender: rep_b,
                   from: platform_number, sent_at: 5.minutes.ago)

      expect { post '/webhooks/twilio/sms/inbound', params: params }
        .not_to change { Communication.where(direction: 'inbound').count }
    end

    it 'does not forward it to a rep who cannot own it' do
      outbound_sms(company: company_b, lead: lead_b, sender: rep_b,
                   from: platform_number, sent_at: 5.minutes.ago)

      post '/webhooks/twilio/sms/inbound', params: params

      expect(TwilioSmsService).not_to have_received(:send_via_master)
        .with(hash_including(to: rep_b.phone))
    end

    it 'still routes a reply that arrives on a tenant\'s own number' do
      outbound_sms(company: company_a, lead: lead_a, sender: rep_a,
                   from: number_a, sent_at: 2.hours.ago)

      expect {
        post '/webhooks/twilio/sms/inbound',
             params: params.merge('To' => number_a)
      }.to change { Communication.where(direction: 'inbound').count }.by(1)
    end
  end
end
