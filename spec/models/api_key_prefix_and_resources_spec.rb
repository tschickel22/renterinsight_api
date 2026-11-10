# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApiKey do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end

  describe 'key prefix' do
    it 'starts new keys dt_live_' do
      key = described_class.create!(name: 'New', company: company, created_by_user: user, rate_limit: 100)
      expect(key.key).to start_with('dt_live_')
      expect(described_class.find_active_by_token(key.key)).to eq(key)
    end

    # Lookup is by digest, so a key minted before the change keeps working.
    it 'still finds a key made with the old ri_live_ prefix' do
      old = described_class.new(name: 'Old', company: company, created_by_user: user, rate_limit: 100)
      old.key = "ri_live_#{SecureRandom.hex(24)}"
      old.save!

      expect(described_class.find_active_by_token(old.key)).to eq(old)
      expect(described_class.api_key_token?(old.key)).to be(true)
      expect(described_class.api_key_token?('dt_live_abc')).to be(true)
      expect(described_class.api_key_token?('eyJhbGciOi')).to be(false)
    end
  end

  describe '.available_resources' do
    before do
      { 'leads' => 'Leads', 'users' => 'Users', 'websites' => 'Websites', 'crm' => 'CRM', 'commissions' => 'Commissions' }.each do |k, n|
        Resource.find_or_create_by!(key: k) { |r| r.name = n; r.active = true }
      end
    end

    it 'offers only resources the partner API checks, with the switches that apply' do
      offered = described_class.available_resources.index_by { |r| r[:resource] }

      expect(offered.keys).to include('leads', 'users', 'websites')
      expect(offered.keys).not_to include('crm', 'commissions')
      expect(offered['leads'][:actions]).to eq(%w[read write])
      expect(offered['users'][:actions]).to eq(%w[read])
      expect(offered['websites'][:actions]).to eq(%w[write])
    end

    it 'keeps an older key that holds a non-partner resource valid' do
      key = described_class.create!(name: 'Old perms', company: company, created_by_user: user, rate_limit: 100,
                                    permissions: { 'crm' => ['read'], 'leads' => ['read'] })
      expect(key.reload.update(rate_limit: 200)).to be(true)
    end
  end
end
