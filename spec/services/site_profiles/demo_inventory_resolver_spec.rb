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

  # Auto-discovery of the internal demo lot, against real records rather than
  # doubles, because the defect was in the SQL and a double cannot show it.
  # Reported from staging: a demo built while switched into Summit Park showed
  # our internal lot's 31 catalog homes instead of their 132.
  describe '.config_for_profile prefers the tenant it was built under' do
    def lot_with_stock(name)
      c = Company.create!(name: "#{name}-#{SecureRandom.hex(3)}")
      c.update!(public_inventory_enabled: true, public_inventory_token: SecureRandom.hex(8))
      c.vehicles.create!(year: 2026, make: 'Clayton', model: 'M', status: 'available',
                         vin: SecureRandom.hex(8).upcase)
      c
    end

    it "uses the profile's own company, and does not call it a sample" do
      own = lot_with_stock('Own')
      profile = SiteContentProfile.new(company: own, company_id: own.id)

      config = described_class.config_for_profile(profile)

      expect(config['company_id']).to eq(own.id)
      expect(config['is_sample']).to be_nil
    end

    # An explicit choice still wins: that is the whole point of the picker.
    it 'lets an explicit lot override the tenant' do
      own = lot_with_stock('Own')
      chosen = lot_with_stock('Chosen')
      profile = SiteContentProfile.new(company: own, company_id: own.id,
                                       inventory_company: chosen, inventory_company_id: chosen.id)

      config = described_class.config_for_profile(profile)

      expect(config['company_id']).to eq(chosen.id)
      expect(config['is_sample']).to be(true)
    end

    it 'falls back to the demo lot when the tenant has nothing to show' do
      empty = Company.create!(name: "Empty-#{SecureRandom.hex(3)}")
      allow(described_class).to receive(:demo_company).and_return(lot_with_stock('Demo'))
      profile = SiteContentProfile.new(company: empty, company_id: empty.id)

      expect(described_class.config_for_profile(profile)['is_sample']).to be(true)
    end
  end

  describe '.demo_company auto-discovery' do
    def saas_tenant_with(status)
      tenant = Company.create!(name: "SaaS-#{SecureRandom.hex(3)}", industry: 'saas')
      tenant.update!(public_inventory_enabled: true, public_inventory_token: SecureRandom.hex(8))
      tenant.vehicles.create!(year: 2026, make: 'Clayton', model: 'Epic', status: status,
                              vin: SecureRandom.hex(8).upcase)
      tenant
    end

    before { allow(PlatformSetting).to receive(:general).and_return({}) }

    # The defect. Our seeded demo lot is catalog-fed from Clayton, Champion and
    # TRU, and catalog stock lands as available_to_order. Filtering on
    # 'available' alone looked for the one status the demo lot does not use, so
    # the lot was never found and demo sites rendered with no homes.
    it 'finds a lot whose stock is available_to_order' do
      tenant = saas_tenant_with('available_to_order')

      expect(described_class.demo_company).to eq(tenant)
    end

    it 'still finds a lot whose stock is available' do
      tenant = saas_tenant_with('available')

      expect(described_class.demo_company).to eq(tenant)
    end

    it 'ignores a lot whose stock is neither' do
      saas_tenant_with('sold')

      expect(described_class.demo_company).to be_nil
    end

    it 'ignores soft-deleted stock' do
      tenant = saas_tenant_with('available_to_order')
      tenant.vehicles.update_all(is_deleted: true)

      expect(described_class.demo_company).to be_nil
    end

    it 'ignores a lot with public inventory switched off' do
      tenant = saas_tenant_with('available_to_order')
      tenant.update!(public_inventory_enabled: false)

      expect(described_class.demo_company).to be_nil
    end
  end

  describe '.usable_config' do
    it 'builds a config for a company with public inventory switched on' do
      config = described_class.usable_config(company(id: 47))

      expect(config).to include('token' => 'tok', 'company_id' => 47, 'enabled' => true)
    end

    # The card travels with the token: it describes how THAT lot presents its
    # listings, so a borrowed demo lot brings its own presentation and a dealer
    # previewing their own homes sees the card they configured.
    it 'carries the lot owner\'s inventory card settings' do
      config = described_class.usable_config(company(id: 47))

      expect(config['card']).to include(layout: 'grid', perPage: 12, showPricing: true)
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

    # A seeded demo account is just a normal company: switch public inventory on
    # and its real stock flows through, with no borrowing and no sample flag.
    it 'uses a real account\'s own inventory even when a demo lot exists' do
      allow(described_class).to receive(:demo_company).and_return(company(id: 61, token: 'demo'))

      config = described_class.config_for(company(id: 47, token: 'their_tok'))
      expect(config['company_id']).to eq(47)
      expect(config['token']).to eq('their_tok')
      expect(config['is_sample']).to be_nil
    end
  end

  describe 'resolution order' do
    it 'honours an explicit Platform Settings pin above auto-detection' do
      allow(PlatformSetting).to receive(:general).and_return(demoInventoryCompanyId: '123')
      expect(described_class.send(:discover_company_id)).to eq(123)
    end

    it 'falls through to our own internal tenant when nothing is pinned' do
      allow(PlatformSetting).to receive(:general).and_return({})
      allow(described_class).to receive(:internal_tenant_id).and_return(61)
      expect(described_class.send(:discover_company_id)).to eq(61)
    end

    # An earlier version fell back to "whichever company has the most
    # inventory", which would drop an unrelated dealer's homes into a pitch
    # without anyone choosing to.
    it 'never borrows an arbitrary customer lot when nothing is ours' do
      allow(PlatformSetting).to receive(:general).and_return({})
      allow(described_class).to receive(:internal_tenant_id).and_return(nil)
      expect(described_class.send(:discover_company_id)).to be_nil
      expect(described_class).not_to respond_to(:best_stocked_id)
    end

    it 'survives a Platform Settings read failing' do
      allow(PlatformSetting).to receive(:general).and_raise(StandardError)
      allow(described_class).to receive(:internal_tenant_id).and_return(61)
      expect(described_class.send(:discover_company_id)).to eq(61)
    end
  end

  describe '.config_for_profile' do
    def profile(company_id:, inventory_company: nil)
      instance_double(
        'SiteContentProfile', company_id: company_id, inventory_company: inventory_company
      )
    end

    # profile.company is only the tenant the admin was switched to when
    # creating the demo, so inheriting it would show an unrelated dealer's
    # homes as though the prospect would be getting them.
    it 'ignores the creating tenant entirely' do
      allow(described_class).to receive(:demo_company).and_return(nil)
      expect(described_class.config_for_profile(profile(company_id: 47))).to be_nil
    end

    it 'uses the nominated demo lot when nothing is chosen, flagged as sample' do
      allow(described_class).to receive(:demo_company).and_return(company(id: 61, token: 'demo'))

      config = described_class.config_for_profile(profile(company_id: 47))
      expect(config['company_id']).to eq(61)
      expect(config['is_sample']).to be(true)
    end

    it 'uses an explicitly chosen lot over the default, flagged as sample' do
      allow(described_class).to receive(:demo_company).and_return(company(id: 61, token: 'demo'))

      config = described_class.config_for_profile(
        profile(company_id: 47, inventory_company: company(id: 88, token: 'chosen'))
      )
      expect(config['company_id']).to eq(88)
      expect(config['token']).to eq('chosen')
      expect(config['is_sample']).to be(true)
    end

    # Rebuilding an existing customer's own site: the homes really are theirs.
    it 'does not flag the lot as sample when the demo is about that company' do
      config = described_class.config_for_profile(
        profile(company_id: 47, inventory_company: company(id: 47, token: 'theirs'))
      )
      expect(config['company_id']).to eq(47)
      expect(config['is_sample']).to be_nil
    end

    it 'omits the block when the chosen lot is not actually usable' do
      config = described_class.config_for_profile(
        profile(company_id: 47, inventory_company: company(id: 88, enabled: false))
      )
      expect(config).to be_nil
    end
  end
end
