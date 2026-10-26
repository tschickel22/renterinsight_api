# frozen_string_literal: true

require 'rails_helper'

# A dealer who brings their own Twilio account. Our Messaging Service belongs to
# our account, and putting it on a send from theirs made Twilio answer 404 for the
# whole message ("The requested resource .../Messages.json was not found"): Easy
# Homesource's test send, 2026-10-21.
RSpec.describe 'A dealer\'s own Twilio account' do
  let(:master_sid) { 'ACmaster0000000000000000000000000' }
  let(:own_sid)    { 'ACdealer0000000000000000000000000' }
  let(:company)    { Company.create!(name: "Own-#{SecureRandom.hex(4)}") }

  around do |example|
    keys  = %w[TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN TWILIO_MESSAGING_SERVICE_SID RAILS_API_URL API_BASE_URL]
    saved = keys.index_with { |k| ENV[k] }
    ENV['TWILIO_ACCOUNT_SID'] = master_sid
    ENV['TWILIO_AUTH_TOKEN'] = 'mastertoken'
    ENV['TWILIO_MESSAGING_SERVICE_SID'] = 'MGmaster'
    ENV['RAILS_API_URL'] = 'https://api.example.com'
    ENV.delete('API_BASE_URL')
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # The form Twilio was sent, and where.
  def capture_send
    sent = {}
    allow(Net::HTTP).to receive(:start) do |*_args, &block|
      http = double('http')
      allow(http).to receive(:request) do |req|
        sent[:path] = req.path
        sent[:form] = URI.decode_www_form(req.body).to_h
        double('response', code: '201', body: { sid: 'SM1', status: 'queued' }.to_json)
      end
      block.call(http)
    end
    sent
  end

  def own_number
    TwilioAccount.create!(company: company, phone_number: '+13525588888', phone_number_sid: 'PNown', status: 'active',
                          sub_account_sid: own_sid, auth_token: 'dealertoken', metadata: { 'own_account' => true })
  end

  describe 'entered in Company Settings (platform mode)' do
    it 'does not inherit our Messaging Service' do
      Setting.set('Company', company.id, 'communications',
                  { 'sms' => { 'provider' => 'twilio', 'fromNumber' => '1352-558-8888', 'twilioAccountSid' => own_sid,
                               'twilioAuthToken' => 'dealertoken', 'isEnabled' => true } })

      cfg = CommunicationSettingsService.for_company(company).sms_config

      expect(cfg[:twilio_account_sid]).to eq(own_sid)
      expect(cfg[:twilio_messaging_service_sid]).to be_nil
    end

    it 'still uses our Messaging Service for a company on our account' do
      cfg = CommunicationSettingsService.for_company(company).sms_config

      expect(cfg[:twilio_messaging_service_sid]).to eq('MGmaster')
    end
  end

  describe 'connected as their own number (dedicated mode)' do
    before do
      own_number
      company.update!(sms_provisioning_mode: 'dedicated')
    end

    it 'sends with their credentials and without our service' do
      cfg = CommunicationSettingsService.for_company(company).sms_config

      expect(cfg).to include(from_number: '+13525588888', twilio_account_sid: own_sid, twilio_auth_token: 'dealertoken',
                             twilio_messaging_service_sid: nil, source: 'dedicated_own_account')
    end

    it 'posts to their account from their number and asks for delivery reports' do
      sent = capture_send

      expect(company.twilio_account.send_sms(to: '3035709810', body: 'Hi')).to include(success: true)
      expect(sent[:path]).to eq("/2010-04-01/Accounts/#{own_sid}/Messages.json")
      expect(sent[:form]).to include('From' => '+13525588888', 'To' => '+13035709810',
                                     'StatusCallback' => 'https://api.example.com/webhooks/twilio/sms/status')
      expect(sent[:form]).not_to have_key('MessagingServiceSid')
    end
  end

  it 'sends a number we provisioned through our account and service, as before' do
    ours = TwilioAccount.create!(company: company, phone_number: '+15551110000', phone_number_sid: 'PNours', status: 'active')
    sent = capture_send

    ours.send_sms(to: '3035709810', body: 'Hi')

    expect(sent[:path]).to eq("/2010-04-01/Accounts/#{master_sid}/Messages.json")
    expect(sent[:form]).to include('MessagingServiceSid' => 'MGmaster', 'From' => '+15551110000')
    expect(sent[:form]).not_to have_key('StatusCallback')
  end

  it 'turns a typed from number into E.164' do
    sent = capture_send

    TwilioSmsService.send(to: '3035709810', body: 'Hi', from_number: '1352-558-8888',
                          account_sid: own_sid, auth_token: 'dealertoken')

    expect(sent[:form]['From']).to eq('+13525588888')
  end

  describe TwilioProvisioningService, '.connect_own_number' do
    let(:numbers) { double('incoming_phone_numbers') }
    let(:number)  { double('incoming_phone_number') }

    before do
      client = double('client', api: double('api'))
      allow(Twilio::REST::Client).to receive(:new).with(own_sid, 'dealertoken').and_return(client)
      allow(client.api).to receive(:incoming_phone_numbers) { |sid = nil| sid ? number : numbers }
    end

    it 'points the number at us and treats it as provisioned' do
      allow(numbers).to receive(:list).with(phone_number: '+13525588888', limit: 1)
                                      .and_return([double(sid: 'PNown', sms_url: 'https://old.example.com/sms')])
      expect(number).to receive(:update).with(sms_url: 'https://api.example.com/webhooks/twilio/sms/inbound', sms_method: 'POST')

      result = TwilioProvisioningService.connect_own_number(company, account_sid: own_sid, auth_token: 'dealertoken',
                                                                     phone_number: '1352-558-8888')

      expect(result).to include(success: true, previous_sms_url: 'https://old.example.com/sms')
      account = company.reload.twilio_account
      expect(account).to have_attributes(phone_number: '+13525588888', phone_number_sid: 'PNown', status: 'active',
                                         sub_account_sid: own_sid, auth_token: 'dealertoken')
      expect(account).to be_own_account
      expect(company.sms_provisioning_mode).to eq('dedicated')
    end

    it 'clears the note that incoming texts go elsewhere when reconnecting' do
      existing = own_number
      existing.update!(metadata: existing.metadata.merge('inbound_to' => 'previous_sms_url',
                                                         'inbound_switched_at' => '2026-10-21T19:28:26Z'))
      allow(numbers).to receive(:list).and_return([double(sid: 'PNown', sms_url: 'https://old.example.com/sms')])
      allow(number).to receive(:update)

      TwilioProvisioningService.connect_own_number(company, account_sid: own_sid, auth_token: 'dealertoken',
                                                            phone_number: '+13525588888')

      expect(company.reload.twilio_account.metadata).not_to include('inbound_to', 'inbound_switched_at')
      expect(company.twilio_account.metadata).to include('previous_sms_url' => 'https://old.example.com/sms')
    end

    it 'refuses a number that is not on their account' do
      allow(numbers).to receive(:list).and_return([])

      result = TwilioProvisioningService.connect_own_number(company, account_sid: own_sid, auth_token: 'dealertoken',
                                                                     phone_number: '+13525588888')

      expect(result[:success]).to be(false)
      expect(company.reload.twilio_account).to be_nil
    end

    it 'gives the number back untouched on deprovision' do
      own_number
      company.update!(sms_provisioning_mode: 'dedicated')
      expect(TwilioProvisioningService).not_to receive(:release_phone_number_from_master)

      expect(TwilioProvisioningService.deprovision_client(company)).to eq(success: true)
      expect(company.reload.sms_provisioning_mode).to eq('platform')
    end
  end
end
