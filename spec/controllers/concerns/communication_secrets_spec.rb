# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationSecrets do
  # Exercise the concern the way a controller does, including the part that
  # actually broke in production: settings arriving as ActionController::Parameters.
  let(:harness) do
    Class.new do
      include CommunicationSecrets
      public :normalize_settings_payload, :restore_masked_secrets,
             :encrypt_sensitive_fields, :mask_sensitive_fields,
             :encrypt_secret, :decrypt_secret, :mask_only?
    end.new
  end

  let(:real_token) { 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6' } # 32-char Twilio auth token
  let(:stored) do
    { 'sms' => { 'twilioAccountSid' => 'AC123', 'twilioAuthToken' => harness.encrypt_secret(real_token) } }
  end

  def round_trip(incoming, existing = stored)
    harness.encrypt_sensitive_fields(harness.restore_masked_secrets(incoming, existing))
  end

  describe 'saving settings the UI just displayed' do
    it 'keeps the stored token when the mask comes back as ActionController::Parameters' do
      incoming = ActionController::Parameters.new(
        sms: { twilioAccountSid: 'AC123', twilioAuthToken: described_class::MASKED_PLACEHOLDER }
      )

      saved = round_trip(incoming)

      expect(harness.decrypt_secret(saved['sms']['twilioAuthToken'])).to eq(real_token)
    end

    it 'keeps the stored token for a mask of any length' do
      incoming = { 'sms' => { 'twilioAuthToken' => '•' * 110 } }

      saved = round_trip(incoming)

      expect(harness.decrypt_secret(saved['sms']['twilioAuthToken'])).to eq(real_token)
    end

    it 'keeps the stored token when the field comes back blank' do
      incoming = { 'sms' => { 'twilioAuthToken' => '' } }

      saved = round_trip(incoming)

      expect(harness.decrypt_secret(saved['sms']['twilioAuthToken'])).to eq(real_token)
    end

    it 'does not re-encrypt an already-encrypted value' do
      incoming = { 'sms' => { 'twilioAuthToken' => stored['sms']['twilioAuthToken'] } }

      saved = round_trip(incoming)

      expect(saved['sms']['twilioAuthToken']).to eq(stored['sms']['twilioAuthToken'])
      expect(harness.decrypt_secret(saved['sms']['twilioAuthToken'])).to eq(real_token)
    end

    it 'takes a genuinely new token' do
      fresh = 'f' * 32
      incoming = { 'sms' => { 'twilioAuthToken' => fresh } }

      saved = round_trip(incoming)

      expect(harness.decrypt_secret(saved['sms']['twilioAuthToken'])).to eq(fresh)
    end

    it 'leaves untouched sections alone' do
      incoming = ActionController::Parameters.new(sms: { fromNumber: '+15551234567' })

      saved = round_trip(incoming)

      expect(saved['sms']['fromNumber']).to eq('+15551234567')
    end
  end

  describe 'refusing to store a mask as a credential' do
    it 'never encrypts a mask, even with nothing on file to fall back to' do
      incoming = { 'sms' => { 'twilioAuthToken' => described_class::MASKED_PLACEHOLDER } }

      saved = round_trip(incoming, {})

      expect(saved['sms']['twilioAuthToken']).to be_nil
    end

    it 'returns nil rather than enciphering a mask handed straight to encrypt_secret' do
      expect(harness.encrypt_secret(described_class::MASKED_PLACEHOLDER)).to be_nil
    end
  end

  describe '#mask_sensitive_fields' do
    it 'replaces stored secrets with the placeholder' do
      masked = harness.mask_sensitive_fields(stored)

      expect(masked['sms']['twilioAuthToken']).to eq(described_class::MASKED_PLACEHOLDER)
      expect(masked['sms']['twilioAccountSid']).to eq('AC123')
    end

    it 'produces something restore_masked_secrets recognises as unchanged' do
      masked = harness.mask_sensitive_fields(stored)

      saved = round_trip(masked)

      expect(harness.decrypt_secret(saved['sms']['twilioAuthToken'])).to eq(real_token)
    end
  end
end
