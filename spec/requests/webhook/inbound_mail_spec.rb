# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Webhook::InboundMail', type: :request do
  let(:verifier) { instance_double(Aws::SNS::MessageVerifier) }

  before { allow(Aws::SNS::MessageVerifier).to receive(:new).and_return(verifier) }

  def post_sns(body)
    post '/webhook/inbound_mail/handle', params: body.to_json,
                                         headers: { 'CONTENT_TYPE' => 'application/json' }
  end

  # This endpoint is public and reaches Campaigns::BounceHandler, which writes suppressions
  # and flags recipients as email_invalid. An unverified message is an unauthenticated write
  # against real customer records, so these are the load-bearing tests here.
  context 'when the SNS signature is invalid' do
    before { allow(verifier).to receive(:authentic?).and_return(false) }

    it 'refuses to process a forged inbound email' do
      expect(InboundEmail::ProcessorService).not_to receive(:new)

      post_sns(
        'Type' => 'Notification',
        'Message' => { 'mail' => { 'messageId' => 'x', 'destination' => ['reply+campaign-1@mail.example'] } }.to_json
      )

      expect(response).to have_http_status(:forbidden)
    end

    it 'refuses to fetch a SubscribeURL, so the endpoint is not an SSRF gadget' do
      expect(Net::HTTP).not_to receive(:get_response)

      post_sns('Type' => 'SubscriptionConfirmation', 'SubscribeURL' => 'http://169.254.169.254/latest/meta-data')

      expect(response).to have_http_status(:forbidden)
    end
  end

  context 'when the SNS signature is valid' do
    before { allow(verifier).to receive(:authentic?).and_return(true) }

    it 'still refuses a SubscribeURL that is not an https AWS host' do
      expect(Net::HTTP).not_to receive(:get_response)

      post_sns('Type' => 'SubscriptionConfirmation', 'SubscribeURL' => 'https://attacker.example.com/confirm')

      expect(response).to have_http_status(:ok)
    end

    it 'still refuses a plain http AWS host' do
      expect(Net::HTTP).not_to receive(:get_response)

      post_sns('Type' => 'SubscriptionConfirmation', 'SubscribeURL' => 'http://sns.us-west-2.amazonaws.com/?x=1')

      expect(response).to have_http_status(:ok)
    end

    it 'confirms a genuine AWS subscription URL' do
      url = 'https://sns.us-west-2.amazonaws.com/?Action=ConfirmSubscription&Token=t'
      expect(Net::HTTP).to receive(:get_response) do |uri|
        expect(uri.to_s).to eq(url)
        Net::HTTPOK.new('1.1', '200', 'OK')
      end

      post_sns('Type' => 'SubscriptionConfirmation', 'SubscribeURL' => url)

      expect(response).to have_http_status(:ok)
    end

    it 'processes a verified notification' do
      processor = instance_double(InboundEmail::ProcessorService, process: { success: true, communication_id: 1 })
      allow(InboundEmail::ProcessorService).to receive(:new).and_return(processor)

      post_sns(
        'Type' => 'Notification',
        'Message' => {
          'mail' => { 'messageId' => 'abc', 'source' => 'a@b.com', 'destination' => ['reply+campaign-1@mail.example'] }
        }.to_json
      )

      expect(response).to have_http_status(:ok)
      expect(processor).to have_received(:process)
    end
  end

  context 'with a malformed body' do
    before { allow(verifier).to receive(:authentic?).and_return(true) }

    it 'returns bad request rather than raising' do
      post '/webhook/inbound_mail/handle', params: 'not json',
                                           headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:bad_request)
    end
  end
end
