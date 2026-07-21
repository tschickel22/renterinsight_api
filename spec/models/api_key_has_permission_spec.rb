# frozen_string_literal: true

require 'rails_helper'

# Regression spec for the "Insufficient permissions" bug that blocked every
# Zapier POST from a key created via the FE (which stores permissions as
# {"leads" => ["read","write"]}) against Partner controllers that check
# specific actions (:create, :update, :delete). The has_permission? matcher
# must treat "write" as implying create + update + delete.
RSpec.describe ApiKey, '#has_permission?', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:creator) do
    User.create!(email: "c-#{SecureRandom.hex(4)}@x.com", first_name: 'C', last_name: 'R',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  def key_with(permissions)
    ApiKey.new(
      company_id: company.id, name: 'k',
      key: "ri_live_#{SecureRandom.hex(24)}",
      permissions: permissions,
      status: 'active',
      created_by_user_id: creator.id
    ).tap { |k| k.save!(validate: false) }
  end

  context 'read/write toggle format (what the FE saves)' do
    let(:k) { key_with('leads' => %w[read write]) }

    it 'grants read' do
      expect(k.has_permission?(:leads, :read)).to be true
    end

    it 'grants create (write implies)' do
      expect(k.has_permission?(:leads, :create)).to be true
    end

    it 'grants update (write implies)' do
      expect(k.has_permission?(:leads, :update)).to be true
    end

    it 'grants delete (write implies)' do
      expect(k.has_permission?(:leads, :delete)).to be true
    end

    it 'does not leak across resources' do
      expect(k.has_permission?(:contacts, :create)).to be false
    end
  end

  context 'read-only (no write)' do
    let(:k) { key_with('leads' => %w[read]) }

    it 'grants read' do
      expect(k.has_permission?(:leads, :read)).to be true
    end

    it 'denies create' do
      expect(k.has_permission?(:leads, :create)).to be false
    end

    it 'denies update' do
      expect(k.has_permission?(:leads, :update)).to be false
    end
  end

  context 'granular action format (explicit create/update/delete)' do
    let(:k) { key_with('leads' => %w[read create update]) }

    it 'grants exactly the listed actions' do
      expect(k.has_permission?(:leads, :read)).to be true
      expect(k.has_permission?(:leads, :create)).to be true
      expect(k.has_permission?(:leads, :update)).to be true
    end

    it 'denies unlisted actions' do
      expect(k.has_permission?(:leads, :delete)).to be false
    end
  end

  context 'empty permissions (legacy behavior)' do
    it 'allows everything when permissions hash is blank (matches existing model docs)' do
      k = key_with({})
      expect(k.has_permission?(:anything, :anything)).to be true
    end
  end
end
