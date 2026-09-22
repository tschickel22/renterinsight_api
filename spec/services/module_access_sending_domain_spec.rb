# frozen_string_literal: true

require 'rails_helper'

# Sending Domain is infrastructure for whatever sends, not a product of its own.
# It used to be a standalone add-on, which made a compliance rule look like an
# upsell: campaign email may not leave through a connected Google mailbox, so a
# Gmail dealer without a verified domain could not run a campaign at all.
RSpec.describe 'Sending Domain module implication' do
  let(:company) do
    Company.create!(name: "Tenant #{SecureRandom.hex(4)}", industry: 'manufactured_housing',
                    subscription_tier: 'starter')
  end

  def grant(key)
    TenantModuleOverride.create!(company_id: company.id, module_key: key, is_enabled: true)
  end

  def access
    ModuleAccessService.new(company.reload)
  end

  it 'is withheld from a tenant that sends nothing' do
    expect(access.has_module?('marketing.sending_domain')).to be(false)
  end

  %w[marketing.campaigns marketing.landing_pages marketing.website].each do |granting|
    it "comes with #{granting}" do
      grant(granting)
      expect(access.has_module?('marketing.sending_domain')).to be(true)
    end
  end

  it 'comes with Campaign Desk through the landing pages it already implies' do
    grant('marketing.automation')

    svc = access
    expect(svc.has_module?('marketing.landing_pages')).to be(true)
    expect(svc.has_module?('marketing.sending_domain')).to be(true)
  end

  it 'stays revoked when an admin has explicitly turned it off' do
    grant('marketing.campaigns')
    TenantModuleOverride.create!(company_id: company.id, module_key: 'marketing.sending_domain',
                                 is_enabled: false)

    expect(access.has_module?('marketing.sending_domain')).to be(false)
  end

  it 'resolves without recursing forever' do
    grant('marketing.automation')
    expect { Timeout.timeout(5) { access.has_module?('marketing.sending_domain') } }.not_to raise_error
  end

  it 'does not hand out unrelated paid add-ons' do
    grant('marketing.campaigns')

    svc = access
    expect(svc.has_module?('marketing.text_us')).to be(false)
    expect(svc.has_module?('marketing.ai_concierge')).to be(false)
  end
end
