# frozen_string_literal: true

require 'rails_helper'

# An AWS key id and its secret are halves of one credential. Resolving them
# independently let a stored-but-undecryptable secret fall back to ENV while the
# key id still came from the DB, producing SignatureDoesNotMatch against a
# secret that was actually valid.
RSpec.describe CommunicationSettingsService, '#aws_credentials' do
  subject(:service) { described_class.platform }

  let(:env_pair) { { 'AWS_ACCESS_KEY_ID' => 'AKIA_ENV_KEY', 'AWS_SECRET_ACCESS_KEY' => 'env-secret' } }

  around do |example|
    original = ENV.to_hash
    env_pair.each { |k, v| ENV[k] = v }
    example.run
    ENV.replace(original)
  end

  def resolve(config)
    service.send(:aws_credentials, config)
  end

  context 'when the stored secret decrypts' do
    it 'uses the stored pair' do
      allow(service).to receive(:decrypt_value).and_return('stored-secret')

      expect(resolve('awsAccessKeyId' => 'AKIA_DB_KEY', 'awsSecretAccessKey' => 'encrypted:abc'))
        .to eq(access_key_id: 'AKIA_DB_KEY', secret_access_key: 'stored-secret')
    end
  end

  context 'when the stored secret fails to decrypt' do
    let(:config) { { 'awsAccessKeyId' => 'AKIA_DB_KEY', 'awsSecretAccessKey' => 'encrypted:corrupt' } }

    before { allow(service).to receive(:decrypt_value).and_return(nil) }

    it 'falls back to the ENV pair instead of mixing sources' do
      expect(resolve(config))
        .to eq(access_key_id: 'AKIA_ENV_KEY', secret_access_key: 'env-secret')
    end

    it 'never pairs the stored key id with the ENV secret' do
      result = resolve(config)

      expect(result.values_at(:access_key_id, :secret_access_key))
        .not_to eq(['AKIA_DB_KEY', 'env-secret'])
    end

    it 'logs why it fell back' do
      expect(Rails.logger).to receive(:error).with(/could not be decrypted/)
      resolve(config)
    end
  end

  context 'when nothing is stored' do
    it 'uses the ENV pair' do
      expect(resolve({})).to eq(access_key_id: 'AKIA_ENV_KEY', secret_access_key: 'env-secret')
    end
  end

  it 'never returns a ciphertext as the secret' do
    allow(service).to receive(:decrypt_value).and_return(nil)

    secret = resolve('awsAccessKeyId' => 'AKIA_DB_KEY', 'awsSecretAccessKey' => 'encrypted:abc')[:secret_access_key]

    expect(secret).not_to start_with('encrypted:')
  end
end
