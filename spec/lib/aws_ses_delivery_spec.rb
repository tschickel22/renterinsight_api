# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/aws_ses_delivery')

RSpec.describe AwsSesDelivery do
  let(:ses_client) { instance_double(Aws::SES::Client) }
  let(:response) { double(message_id: '0100018f-ses-assigned-id') }

  let(:settings) do
    { access_key_id: 'AKIATEST', secret_access_key: 'secret', region: 'us-west-2' }
  end

  let(:mail) do
    Mail.new do
      from    'sender@example.com'
      to      'recipient@example.com'
      subject 'Hi'
      body    'hello'
    end
  end

  before do
    allow(Aws::SES::Client).to receive(:new).and_return(ses_client)
    allow(ses_client).to receive(:send_raw_email).and_return(response)
  end

  it 'exposes the SES-assigned MessageId, not the RFC Message-ID header' do
    delivery = described_class.new(settings)
    delivery.deliver!(mail)

    expect(delivery.ses_message_id).to eq('0100018f-ses-assigned-id')
    expect(delivery.ses_message_id).not_to eq(mail.message_id)
  end

  # This is the path AwsSesProvider reads the id back through. ActionMailer's
  # MessageDelivery delegates both #delivery_method and #deliver_now to the underlying
  # Mail::Message, so exercising the message directly covers the same wiring.
  it 'is reachable through mail.delivery_method after delivering' do
    mail.delivery_method(described_class, settings)
    mail.deliver

    expect(mail.delivery_method.ses_message_id).to eq('0100018f-ses-assigned-id')
  end

  it 'attaches the configuration set header so SES publishes events' do
    delivery = described_class.new(settings.merge(configuration_set: 'dealertide-events'))
    delivery.deliver!(mail)

    expect(mail['X-SES-CONFIGURATION-SET'].to_s).to eq('dealertide-events')
  end

  it 'omits the header when no configuration set is configured' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SES_CONFIGURATION_SET').and_return(nil)

    described_class.new(settings).deliver!(mail)

    expect(mail['X-SES-CONFIGURATION-SET']).to be_nil
  end
end
