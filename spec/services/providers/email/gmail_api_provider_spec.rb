# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Providers::Email::GmailApiProvider do
  let(:raw) { "From: a@example.com\r\nTo: b@example.com\r\nSubject: Hi\r\n\r\nBody" }

  def stub_send(code:, body:)
    response = instance_double(Net::HTTPResponse, code: code.to_s, body: body.to_json)
    allow(Net::HTTP).to receive(:start).and_return(response)
    response
  end

  describe '.deliver_raw' do
    it 'returns our own RFC Message-ID rather than Gmail internal id' do
      stub_send(code: 200, body: { 'id' => 'gmail-internal-abc' })

      result = described_class.deliver_raw(
        raw_message: raw, access_token: 'tok', message_id: '<ours@srv.mail>'
      )

      expect(result[:success]).to be true
      expect(result[:message_id]).to eq('<ours@srv.mail>')
      expect(result[:gmail_id]).to eq('gmail-internal-abc')
    end

    it 'falls back to the Gmail id when no Message-ID was supplied' do
      stub_send(code: 200, body: { 'id' => 'gmail-internal-abc' })

      result = described_class.deliver_raw(raw_message: raw, access_token: 'tok')
      expect(result[:message_id]).to eq('gmail-internal-abc')
    end

    it 'surfaces the API error message on failure' do
      stub_send(code: 403, body: { 'error' => { 'message' => 'Request had insufficient authentication scopes.' } })

      result = described_class.deliver_raw(raw_message: raw, access_token: 'tok')
      expect(result[:success]).to be false
      expect(result[:error]).to match(/insufficient authentication scopes/)
    end

    it 'refuses to send an empty message' do
      result = described_class.deliver_raw(raw_message: '', access_token: 'tok')
      expect(result[:success]).to be false
    end

    it 'fails clearly when there is no token and no way to mint one' do
      result = described_class.deliver_raw(raw_message: raw, access_token: nil)
      expect(result[:success]).to be false
      expect(result[:error]).to match(/Reconnect/i)
    end

    # An expired access token is routine, so one refresh and retry should
    # recover it rather than surfacing a failure to the user.
    it 'refreshes and retries once on 401' do
      unauthorized = instance_double(Net::HTTPResponse, code: '401', body: '{}')
      ok = instance_double(Net::HTTPResponse, code: '200', body: { 'id' => 'sent-after-refresh' }.to_json)
      allow(Net::HTTP).to receive(:start).and_return(unauthorized, ok)
      allow(described_class).to receive(:refresh_access_token).and_return('fresh-token')

      result = described_class.deliver_raw(
        raw_message: raw, access_token: 'stale', refresh_token: 'rtok'
      )

      expect(described_class).to have_received(:refresh_access_token).once
      expect(result[:success]).to be true
      expect(result[:gmail_id]).to eq('sent-after-refresh')
    end

    it 'does not retry when there is no refresh token' do
      stub_send(code: 401, body: {})
      allow(described_class).to receive(:refresh_access_token)

      result = described_class.deliver_raw(raw_message: raw, access_token: 'stale')

      expect(described_class).not_to have_received(:refresh_access_token)
      expect(result[:success]).to be false
    end

    it 'mints a token up front when only a refresh token is present' do
      stub_send(code: 200, body: { 'id' => 'ok' })
      allow(described_class).to receive(:refresh_access_token).and_return('minted')

      result = described_class.deliver_raw(raw_message: raw, access_token: nil, refresh_token: 'rtok')

      expect(described_class).to have_received(:refresh_access_token).once
      expect(result[:success]).to be true
    end

    it 'returns a failure rather than raising when the request blows up' do
      allow(Net::HTTP).to receive(:start).and_raise(SocketError, 'getaddrinfo failed')

      result = described_class.deliver_raw(raw_message: raw, access_token: 'tok')
      expect(result[:success]).to be false
      expect(result[:error]).to match(/getaddrinfo/)
    end
  end
end
