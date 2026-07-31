# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::DemoInventoryResolver do
  # Stand-ins so the spec does not depend on factory shape.
  def company(id:, enabled: true, token: 'tok')
    instance_double(
      'Company', id: id, public_inventory_enabled: enabled, public_inventory_token: token
    )
  end

  before { described_class.clear_cache! }
  after { described_class.clear_cache! }

  describe '.usable_config' do
    it 'builds a config for a company with public inventory switched on' do
      expect(described_class.usable_config(company(id: 47)))
        .to eq('token' => 'tok', 'company_id' => 47, 'enabled' => true)
    end

    it 'rejects a company with the feature off, even if a token exists' do
      expect(described_class.usable_config(company(id: 47, enabled: false))).to be_nil
    end

    it 'rejects a company with no token' do
      expect(described_class.usable_config(company(id: 47, token: ''))).to be_nil
      expect(described_class.usable_config(company(id: 47, token: nil))).to be_nil
    end

    it 'rejects nil' do
      expect(described_class.usable_config(nil)).to be_nil
    end
  end

  describe '.config_for' do
    it "prefers the company's own inventory and does not mark it as sample" do
      config = described_class.config_for(company(id: 47))
      expect(config['company_id']).to eq(47)
      expect(config['is_sample']).to be_nil
    end

    # The point of the fallback: a prospect demo account has no inventory, and
    # an unbound inventory block renders the "not configured" placeholder.
    it 'borrows a demo lot when the company has none, flagged as sample' do
      allow(described_class).to receive(:demo_company).and_return(company(id: 61, token: 'demo_tok'))

      config = described_class.config_for(company(id: 99, enabled: false))
      expect(config['company_id']).to eq(61)
      expect(config['token']).to eq('demo_tok')
      expect(config['is_sample']).to be(true)
    end

    it 'never borrows from itself' do
      allow(described_class).to receive(:demo_company).and_return(company(id: 61, token: 'demo'))
      expect(described_class.config_for(company(id: 61, enabled: false))).to be_nil
    end

    it 'returns nil rather than a broken config when no demo lot exists' do
      allow(described_class).to receive(:demo_company).and_return(nil)
      expect(described_class.config_for(company(id: 99, enabled: false))).to be_nil
    end

    it 'can be told not to fall back' do
      allow(described_class).to receive(:demo_company).and_return(company(id: 61))
      expect(described_class.config_for(company(id: 99, enabled: false), allow_fallback: false)).to be_nil
    end
  end

  describe 'resolution order' do
    it 'honours an explicit Platform Settings pin above auto-detection' do
      allow(PlatformSetting).to receive(:general).and_return(demoInventoryCompanyId: '123')
      expect(described_class.send(:discover_company_id)).to eq(123)
    end

    it 'falls through to auto-detection when nothing is pinned' do
      allow(PlatformSetting).to receive(:general).and_return({})
      allow(described_class).to receive(:internal_tenant_id).and_return(61)
      expect(described_class.send(:discover_company_id)).to eq(61)
    end

    it 'survives a Platform Settings read failing' do
      allow(PlatformSetting).to receive(:general).and_raise(StandardError)
      allow(described_class).to receive(:internal_tenant_id).and_return(61)
      expect(described_class.send(:discover_company_id)).to eq(61)
    end
  end
end
