# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Webhooks::Zego', type: :request do
  # These endpoints reach HandlePaymentUpdateJob, which marks a payment completed from an
  # id in the request body. Anything that gets past the token check is an unauthenticated
  # financial write, so these are the load-bearing tests.
  let(:payload) { { payment_reference_id: 'PAY-123', amount: '500.00' } }

  def post_callback(path, params = {})
    post "/webhooks/zego/#{path}", params: payload.merge(params)
  end

  around do |example|
    original = ENV['ZEGO_WEBHOOK_TOKEN']
    example.run
    ENV['ZEGO_WEBHOOK_TOKEN'] = original
  end

  context 'when no token is configured' do
    before { ENV['ZEGO_WEBHOOK_TOKEN'] = nil }

    it 'rejects the callback, since no tenant is live on Zego' do
      expect(HandlePaymentUpdateJob).not_to receive(:perform_later)

      post_callback('processed')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects even when the caller supplies a token' do
      expect(HandlePaymentUpdateJob).not_to receive(:perform_later)

      post_callback('processed', token: 'anything')

      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'when a token is configured' do
    before { ENV['ZEGO_WEBHOOK_TOKEN'] = 'sekret-token' }

    it 'rejects a request with no token' do
      expect(HandlePaymentUpdateJob).not_to receive(:perform_later)

      post_callback('processed')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a request with the wrong token' do
      expect(HandlePaymentUpdateJob).not_to receive(:perform_later)

      post_callback('canceled', token: 'wrong')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'accepts a request with the right token' do
      expect(HandlePaymentUpdateJob).to receive(:perform_later)

      post_callback('processed', token: 'sekret-token')

      expect(response).to have_http_status(:ok)
    end

    it 'accepts the token via header as well as query param' do
      expect(HandlePaymentUpdateJob).to receive(:perform_later)

      post '/webhooks/zego/processed', params: payload, headers: { 'X-Zego-Token' => 'sekret-token' }

      expect(response).to have_http_status(:ok)
    end

    it 'does not persist the shared secret into the job payload' do
      forwarded = nil
      allow(HandlePaymentUpdateJob).to receive(:perform_later) { |_status, json| forwarded = json }

      post_callback('processed', token: 'sekret-token')

      expect(forwarded).to include('PAY-123')
      expect(forwarded).not_to include('sekret-token')
    end
  end
end
