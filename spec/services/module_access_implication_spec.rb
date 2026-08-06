# frozen_string_literal: true

require 'rails_helper'

# Campaign Desk always includes Landing Pages. Its own description promises a
# landing page, so a tenant with the Desk and no landing pages would have bought
# something that cannot do what it says.
RSpec.describe ModuleAccessService, 'implied modules' do
  let(:company) { Company.create!(name: "Mod-#{SecureRandom.hex(4)}") }
  subject(:access) { described_class.new(company) }

  def grant(key, enabled: true)
    company.tenant_module_overrides.create!(module_key: key, is_enabled: enabled)
  end

  it 'registers landing pages as a real module' do
    expect(PlatformModule.valid_key?('marketing.landing_pages')).to be(true)
  end

  # Both are sold, not bundled into a tier — landing on professional or
  # enterprise must not grant either for free.
  it 'keeps both out of every plan template' do
    PlatformModule::PLAN_TEMPLATES.each_value do |keys|
      expect(keys).not_to include('marketing.automation')
      expect(keys).not_to include('marketing.landing_pages')
    end
  end

  it 'grants landing pages to a company that has Campaign Desk' do
    grant('marketing.automation')

    expect(access.has_module?('marketing.landing_pages')).to be(true)
  end

  it 'includes the implied module in the enabled list, so nav and API agree' do
    grant('marketing.automation')

    expect(described_class.new(company).enabled_modules).to include('marketing.landing_pages')
  end

  # The manual-add path for tenants without the Desk.
  it 'grants landing pages standalone without Campaign Desk' do
    grant('marketing.landing_pages')

    expect(access.has_module?('marketing.landing_pages')).to be(true)
    expect(access.has_module?('marketing.automation')).to be(false)
  end

  it 'grants neither by default' do
    expect(access.has_module?('marketing.landing_pages')).to be(false)
    expect(access.has_module?('marketing.automation')).to be(false)
  end

  # An implication must never undo a deliberate revocation.
  it 'respects an override that explicitly disables the implied module' do
    grant('marketing.automation')
    grant('marketing.landing_pages', enabled: false)

    expect(described_class.new(company).has_module?('marketing.landing_pages')).to be(false)
    expect(described_class.new(company).enabled_modules).not_to include('marketing.landing_pages')
  end

  # The implication runs one way only.
  it 'does not grant Campaign Desk to someone who bought landing pages' do
    grant('marketing.landing_pages')

    expect(access.has_module?('marketing.automation')).to be(false)
  end

  it 'is independent of the website module' do
    grant('marketing.landing_pages')

    expect(access.has_module?('marketing.landing_pages')).to be(true)
    expect(access.has_module?('marketing.website')).to be(false)
  end

  # Regression: enabled_modules appended tenant overrides straight onto the
  # array PLAN_TEMPLATES holds, so one tenant's paid add-on became part of the
  # starter template for every other company in the process until restart.
  describe 'plan template isolation' do
    it 'does not leak one tenant\'s overrides into the shared plan template' do
      before = PlatformModule::PLAN_TEMPLATES[:starter].dup
      grant('marketing.automation')

      described_class.new(company).enabled_modules

      expect(PlatformModule::PLAN_TEMPLATES[:starter]).to eq(before)
    end

    it 'does not leak between two companies' do
      grant('marketing.automation')
      described_class.new(company).enabled_modules

      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      expect(described_class.new(other).enabled_modules).not_to include('marketing.automation')
      expect(described_class.new(other).has_module?('marketing.landing_pages')).to be(false)
    end

    it 'hands callers a copy they can safely mutate' do
      expect(PlatformModule.template_modules(:starter))
        .not_to equal(PlatformModule.template_modules(:starter))
    end

    # Freezing only the hash leaves the arrays mutable; this makes any remaining
    # in-place write raise instead of corrupting quietly.
    it 'freezes the templates themselves' do
      expect(PlatformModule::PLAN_TEMPLATES.values).to all(be_frozen)
    end
  end

  it 'does not loop when resolving' do
    grant('marketing.automation')

    expect { access.has_module?('marketing.landing_pages') }.not_to raise_error
    expect { access.has_module?('marketing.automation') }.not_to raise_error
  end
end
