# frozen_string_literal: true

require 'rails_helper'

# These cover the two resolvers that decide where a provisioned number points and
# whether it makes it into the A2P sender pool. Both used to fail silently: the
# webhook fell back to a hardcoded staging host, and a blank env var beat the
# settings fallback, so a production provision could report success while pointing
# a real customer number at staging and leaving it out of the pool.
RSpec.describe TwilioProvisioningService do
  around do |example|
    keys  = %w[API_BASE_URL RAILS_API_URL TWILIO_MESSAGING_SERVICE_SID]
    saved = keys.index_with { |k| ENV[k] }
    keys.each { |k| ENV.delete(k) }
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  describe '.api_base_url' do
    it 'prefers API_BASE_URL' do
      ENV['API_BASE_URL']  = 'https://explicit.example.com'
      ENV['RAILS_API_URL'] = 'https://fallback.example.com'

      expect(described_class.api_base_url).to eq('https://explicit.example.com')
    end

    it 'falls back to RAILS_API_URL, which is the var actually set on Render' do
      ENV['RAILS_API_URL'] = 'https://renterinsight-api-prod.onrender.com'

      expect(described_class.api_base_url).to eq('https://renterinsight-api-prod.onrender.com')
    end

    it 'treats an empty API_BASE_URL as unset rather than as a value' do
      ENV['API_BASE_URL']  = ''
      ENV['RAILS_API_URL'] = 'https://renterinsight-api-prod.onrender.com'

      expect(described_class.api_base_url).to eq('https://renterinsight-api-prod.onrender.com')
    end

    it 'strips a trailing slash so the webhook path does not double up' do
      ENV['RAILS_API_URL'] = 'https://renterinsight-api-prod.onrender.com/'

      expect(described_class.inbound_webhook_url)
        .to eq('https://renterinsight-api-prod.onrender.com/webhooks/twilio/sms/inbound')
    end

    it 'raises instead of defaulting to a hardcoded host when neither is set' do
      expect { described_class.api_base_url }
        .to raise_error(TwilioProvisioningService::ProvisioningError, /API_BASE_URL or RAILS_API_URL/)
    end
  end

  describe '.inbound_webhook_url' do
    it 'matches the route the app actually serves' do
      ENV['RAILS_API_URL'] = 'https://renterinsight-api-staging.onrender.com'

      expect(described_class.inbound_webhook_url)
        .to eq('https://renterinsight-api-staging.onrender.com/webhooks/twilio/sms/inbound')
      expect(Rails.application.routes.recognize_path('/webhooks/twilio/sms/inbound', method: :post))
        .to include(controller: 'webhooks/twilio', action: 'sms_inbound')
    end
  end

  describe '.messaging_service_sid' do
    it 'uses the env var when set' do
      ENV['TWILIO_MESSAGING_SERVICE_SID'] = 'MG892b7f2caac02ee3110efd23d5a85330'

      expect(described_class.messaging_service_sid).to eq('MG892b7f2caac02ee3110efd23d5a85330')
    end

    it 'falls through to platform settings when the env var is an empty string' do
      ENV['TWILIO_MESSAGING_SERVICE_SID'] = ''
      allow(Setting).to receive(:get).with('Platform', 0, 'communications')
                                     .and_return('sms' => { 'twilioMessagingServiceSid' => 'MGfromsettings' })

      expect(described_class.messaging_service_sid).to eq('MGfromsettings')
    end

    it 'is nil when configured nowhere' do
      allow(Setting).to receive(:get).with('Platform', 0, 'communications').and_return(nil)

      expect(described_class.messaging_service_sid).to be_nil
    end
  end

  describe '.enroll_in_messaging_service' do
    it 'reports the miss instead of returning silently when no SID is configured' do
      allow(Setting).to receive(:get).with('Platform', 0, 'communications').and_return(nil)

      result = described_class.send(:enroll_in_messaging_service, 'PN123', '+17205752095')

      expect(result[:enrolled]).to be(false)
      expect(result[:warning]).to include('TWILIO_MESSAGING_SERVICE_SID')
      expect(result[:warning]).to include('+17205752095')
    end

    it 'reports the miss when Twilio rejects the enrollment, without raising' do
      ENV['TWILIO_MESSAGING_SERVICE_SID'] = 'MGbroken'
      allow(described_class).to receive(:master_client).and_raise(StandardError, 'Service not found')

      result = described_class.send(:enroll_in_messaging_service, 'PN123', '+17205752095')

      expect(result[:enrolled]).to be(false)
      expect(result[:messaging_service_sid]).to eq('MGbroken')
      expect(result[:warning]).to include('Service not found')
    end
  end
end
