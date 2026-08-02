# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Webhooks::SesEvents', type: :request do
  let(:verifier) { instance_double(Aws::SNS::MessageVerifier) }

  before do
    allow(Aws::SNS::MessageVerifier).to receive(:new).and_return(verifier)
  end

  def post_sns(body)
    post '/webhooks/ses/events', params: body.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
  end

  context 'when the SNS signature is valid' do
    before { allow(verifier).to receive(:authentic?).and_return(true) }

    it 'hands a notification to the event processor' do
      payload = { 'eventType' => 'Delivery', 'mail' => { 'messageId' => 'abc' } }
      expect(Ses::EventProcessor).to receive(:process).with(payload.to_json)
        .and_return(Ses::EventProcessor::Result.new(handled: true, event_type: 'Delivery'))

      post_sns('Type' => 'Notification', 'Message' => payload.to_json)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['handled']).to be true
    end

    it 'confirms a subscription whose SubscribeURL is an AWS host' do
      confirm_url = 'https://sns.us-west-2.amazonaws.com/?Action=ConfirmSubscription&Token=t'
      expect(Net::HTTP).to receive(:get_response) do |uri|
        expect(uri.to_s).to eq(confirm_url)
        Net::HTTPOK.new('1.1', '200', 'OK')
      end

      post_sns(
        'Type' => 'SubscriptionConfirmation',
        'TopicArn' => 'arn:aws:sns:us-west-2:1:ses-events',
        'SubscribeURL' => confirm_url
      )

      expect(response).to have_http_status(:ok)
    end

    it 'refuses to fetch a SubscribeURL pointing somewhere other than AWS' do
      expect(Net::HTTP).not_to receive(:get_response)

      post_sns(
        'Type' => 'SubscriptionConfirmation',
        'SubscribeURL' => 'https://attacker.example.com/confirm'
      )

      expect(response).to have_http_status(:ok)
    end
  end

  context 'when the SNS signature is invalid' do
    before { allow(verifier).to receive(:authentic?).and_return(false) }

    it 'rejects the message without processing it' do
      expect(Ses::EventProcessor).not_to receive(:process)

      post_sns('Type' => 'Notification', 'Message' => '{}')

      expect(response).to have_http_status(:forbidden)
    end

    it 'rejects a forged bounce rather than suppressing the address' do
      expect(Ses::EventProcessor).not_to receive(:process)

      post_sns(
        'Type' => 'Notification',
        'Message' => { 'eventType' => 'Bounce', 'mail' => { 'messageId' => 'x' } }.to_json
      )

      expect(response).to have_http_status(:forbidden)
    end
  end

  context 'with a malformed body' do
    before { allow(verifier).to receive(:authentic?).and_return(true) }

    it 'returns bad request rather than raising' do
      post '/webhooks/ses/events', params: 'not json',
                                   headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:bad_request)
    end
  end
end
