# frozen_string_literal: true

require 'rails_helper'

RSpec.describe JsonWebToken do
  describe '.encode' do
    it 'encodes a payload into a JWT token' do
      payload = { user_id: 123 }
      token = described_class.encode(payload)

      expect(token).to be_a(String)
      expect(token.split('.').length).to eq(3) # JWT has 3 parts
    end

    it 'includes expiration time in the payload' do
      payload = { user_id: 123 }
      exp_time = 2.hours.from_now

      token = described_class.encode(payload, exp_time)
      decoded = described_class.decode(token)

      expect(decoded[:exp]).to be_within(2).of(exp_time.to_i)
    end

    it 'defaults to 24 hours expiration' do
      payload = { user_id: 123 }
      token = described_class.encode(payload)
      decoded = described_class.decode(token)

      expect(decoded[:exp]).to be_within(2).of(24.hours.from_now.to_i)
    end
  end

  describe '.decode' do
    it 'decodes a valid JWT token' do
      payload = { user_id: 123, name: 'Test User' }
      token = described_class.encode(payload)
      decoded = described_class.decode(token)

      expect(decoded[:user_id]).to eq(123)
      expect(decoded[:name]).to eq('Test User')
    end

    it 'returns nil for an invalid token' do
      invalid_token = 'invalid.token.here'
      result = described_class.decode(invalid_token)

      expect(result).to be_nil
    end

    it 'returns nil for an expired token' do
      payload = { user_id: 123 }
      token = described_class.encode(payload, 1.second.ago)
      
      sleep(0.1) # Ensure token is expired
      result = described_class.decode(token)

      expect(result).to be_nil
    end

    it 'returns a HashWithIndifferentAccess' do
      payload = { user_id: 123 }
      token = described_class.encode(payload)
      decoded = described_class.decode(token)

      expect(decoded).to be_a(HashWithIndifferentAccess)
      expect(decoded[:user_id]).to eq(123)
      expect(decoded['user_id']).to eq(123)
    end
  end

  describe 'roundtrip encoding and decoding' do
    it 'preserves payload data' do
      original_payload = {
        buyer_portal_access_id: 456,
        email: 'test@example.com',
        role: 'buyer',
        metadata: { plan: 'premium' }
      }

      token = described_class.encode(original_payload)
      decoded = described_class.decode(token)

      expect(decoded[:buyer_portal_access_id]).to eq(456)
      expect(decoded[:email]).to eq('test@example.com')
      expect(decoded[:role]).to eq('buyer')
      expect(decoded[:metadata]).to eq({ 'plan' => 'premium' })
    end
  end
end
