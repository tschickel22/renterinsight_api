# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::TrackingUrl do
  around do |example|
    original = ENV.to_hash.slice('DMS_API_URL', 'CAMPAIGN_BASE_URL', 'APP_BASE_URL', 'APP_URL', 'FRONTEND_URL')
    %w[DMS_API_URL CAMPAIGN_BASE_URL APP_BASE_URL APP_URL FRONTEND_URL].each { |k| ENV.delete(k) }
    example.run
    %w[DMS_API_URL CAMPAIGN_BASE_URL APP_BASE_URL APP_URL FRONTEND_URL].each { |k| ENV.delete(k) }
    original.each { |k, v| ENV[k] = v }
  end

  describe '.base' do
    it 'prefers DMS_API_URL' do
      ENV['DMS_API_URL'] = 'https://api.example.com'
      ENV['CAMPAIGN_BASE_URL'] = 'https://other.example.com'
      expect(described_class.base).to eq('https://api.example.com')
    end

    it 'falls back to CAMPAIGN_BASE_URL' do
      ENV['CAMPAIGN_BASE_URL'] = 'https://other.example.com'
      expect(described_class.base).to eq('https://other.example.com')
    end

    it 'strips a trailing slash so callers can concatenate paths' do
      ENV['DMS_API_URL'] = 'https://api.example.com/'
      expect(described_class.base).to eq('https://api.example.com')
    end

    # The regression this class exists for: open tracking was resolved from
    # APP_BASE_URL, which points at the frontend SPA. The pixel then 404/406'd
    # and not a single open was ever recorded.
    it 'ignores frontend host variables entirely' do
      ENV['APP_BASE_URL'] = 'https://app.dealertide.com'
      ENV['APP_URL'] = 'https://app.dealertide.com'
      ENV['FRONTEND_URL'] = 'https://app.dealertide.com'
      expect(described_class.base).not_to include('app.dealertide.com')
    end

    it 'defaults to the production API host in production, never staging' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))
      expect(described_class.base).to eq('https://renterinsight-api-prod.onrender.com')
    end

    it 'defaults to the staging API host outside production' do
      expect(described_class.base).to eq('https://renterinsight-api-staging.onrender.com')
    end
  end
end
