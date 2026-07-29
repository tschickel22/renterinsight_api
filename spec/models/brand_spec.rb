# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Brand, type: :model do
  before do
    Setting.where(scope_type: 'Platform', scope_id: 0).destroy_all
  end

  describe '.current with defaults only' do
    it 'exposes the ENV-fallback kernel from PlatformSetting.general' do
      brand = Brand.current

      expect(brand.name).to eq('RenterInsight')
      expect(brand.support_email).to eq('support@renterinsight.com')
      expect(brand.from_email).to eq('noreply@renterinsight.com')
      expect(brand.from_name).to eq('RenterInsight')
      expect(brand.website_url).to eq('https://renterinsight.com')
      expect(brand.privacy_url).to eq('https://www.renterinsight.com/privacy-policy/')
      expect(brand.terms_url).to eq('https://www.renterinsight.com/terms-of-use/')
      expect(brand.subdomain_root).to eq('renterinsight.com')
    end

    it 'falls back short_name to name when not set' do
      expect(Brand.current.short_name).to eq('RenterInsight')
    end
  end

  describe '.current with persisted platform overrides' do
    before do
      PlatformSetting.general = {
        platformName: 'DealerTide',
        supportEmail: 'support@dealertide.com',
        fromEmail: 'noreply@dealertide.com',
        fromName: 'DealerTide',
        websiteUrl: 'https://dealertide.com',
        appUrl: 'https://app.dealertide.com',
        privacyUrl: 'https://dealertide.com/privacy',
        termsUrl: 'https://dealertide.com/terms',
        subdomainRoot: 'dealertide.com'
      }
    end

    it 'returns the persisted kernel' do
      brand = Brand.current

      expect(brand.name).to eq('DealerTide')
      expect(brand.support_email).to eq('support@dealertide.com')
      expect(brand.website_url).to eq('https://dealertide.com')
      expect(brand.subdomain_root).to eq('dealertide.com')
    end

    it 'preserves defaults for keys that were not persisted' do
      # Simulate a legacy save that only set platformName
      Setting.set('Platform', 0, 'general', { platformName: 'DealerTide' })

      brand = Brand.current
      expect(brand.name).to eq('DealerTide')
      # New kernel keys still resolve to their ENV defaults
      expect(brand.privacy_url).to eq('https://www.renterinsight.com/privacy-policy/')
      expect(brand.subdomain_root).to eq('renterinsight.com')
    end
  end

  describe '.current with company overrides (whitelabel design intent)' do
    let(:company) { Company.create!(name: 'Acme Homes RV') }

    before do
      PlatformSetting.general = {
        platformName: 'DealerTide',
        supportEmail: 'support@dealertide.com',
        websiteUrl: 'https://dealertide.com'
      }
    end

    it 'degrades to platform-only when Company#branding_overrides column is absent' do
      # Column doesn't exist yet — resolver must not raise.
      brand = Brand.current(company: company)
      expect(brand.name).to eq('DealerTide')
    end

    it 'layers company overrides over platform when the column is present' do
      # Simulate a future migration adding companies.branding_overrides JSONB
      unless Company.column_names.include?('branding_overrides')
        skip 'branding_overrides column not yet migrated; whitelabel path deferred to future PR'
      end

      company.update!(branding_overrides: {
        name: 'Acme Fleet Portal',
        support_email: 'help@acmefleet.com'
      })

      brand = Brand.current(company: company)
      expect(brand.name).to eq('Acme Fleet Portal')
      expect(brand.support_email).to eq('help@acmefleet.com')
      # Non-overridden keys still come from platform
      expect(brand.website_url).to eq('https://dealertide.com')
    end
  end

  describe '#to_h' do
    it 'returns a flat hash keyed by kernel attributes' do
      hash = Brand.current.to_h
      expect(hash.keys).to match_array(Brand::ATTRIBUTES)
    end
  end

  # Every user-facing frontend link (mailer deep links, notification "view in
  # app", unsubscribe page) resolves here, so a single Platform Admin change
  # or ENV var moves all of them together.
  describe '.app_url' do
    around do |example|
      original = ENV['APP_URL']
      ENV.delete('APP_URL')
      example.run
      original.nil? ? ENV.delete('APP_URL') : ENV['APP_URL'] = original
    end

    it 'reads APP_URL when no platform override is set' do
      ENV['APP_URL'] = 'https://app.from-env.com'
      expect(Brand.app_url).to eq('https://app.from-env.com')
    end

    it 'lets a Platform Admin override win over ENV' do
      ENV['APP_URL'] = 'https://app.from-env.com'
      PlatformSetting.general = { appUrl: 'https://app.from-admin.com' }
      expect(Brand.app_url).to eq('https://app.from-admin.com')
    end

    it 'falls back to the environment default when nothing is configured' do
      expect(Brand.app_url).to eq('https://localhost:5173')
    end

    # Callers are mailers and notification services — a settings-lookup
    # failure must degrade to a usable URL, not blow up the send.
    it 'returns a usable URL when the settings lookup raises' do
      allow(PlatformSetting).to receive(:general).and_raise(StandardError, 'db down')
      expect(Brand.app_url).to eq('https://localhost:5173')
    end

    it 'never returns the stale renterinsight app host as a default' do
      expect(Brand.app_url).not_to include('app.renterinsight.com')
    end
  end

  # Mailers, jobs and services used to each carry their own
  # 'noreply@renterinsight.com' literal, so changing the platform From
  # address in Platform Admin left a dozen senders on the old brand.
  describe '.from_email / .from_name' do
    it 'returns the persisted platform sender identity' do
      PlatformSetting.general = {
        fromEmail: 'alerts@notifications.dealertide.com',
        fromName: 'DealerTide'
      }

      expect(Brand.from_email).to eq('alerts@notifications.dealertide.com')
      expect(Brand.from_name).to eq('DealerTide')
    end

    it 'falls back to the ENV-driven defaults when nothing is persisted' do
      expect(Brand.from_email).to eq(PlatformSetting.default_general[:fromEmail])
      expect(Brand.from_name).to eq(PlatformSetting.default_general[:fromName])
    end

    # The callers are password reset, MFA and transactional mailers — a
    # settings failure must still yield a usable sender, not raise.
    it 'still returns a usable sender when the settings lookup raises' do
      allow(PlatformSetting).to receive(:general).and_raise(StandardError, 'db down')

      expect(Brand.from_email).to be_present
      expect(Brand.from_name).to be_present
    end
  end
end
