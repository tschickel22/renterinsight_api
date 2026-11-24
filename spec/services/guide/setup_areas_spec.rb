# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# my_setup must cover every module (E118): a new module cannot ship without
# someone deciding what help can read about it.
RSpec.describe Guide::SetupAreas do
  include McpConnectorHelpers

  it 'has an entry for every plan module, and nothing else' do
    expect(described_class::AREAS.keys).to match_array(PlatformModule::MODULES.keys)
  end

  it 'gives every module that reads facts a permission to check' do
    described_class::AREAS.each do |key, area|
      next if area[:not_offered] || area[:platform_only]

      expect(area[:resource]).to be_present, "#{key} has no resource"
      expect(area[:facts].present? || area[:reader].present?).to be(true), "#{key} reads nothing"
    end
  end

  context 'reading every module for an admin' do
    let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}", industry: 'manufactured_housing', use_rbac_system: false) }
    let(:user) do
      company.users.create!(email: "a-#{SecureRandom.hex(3)}@example.com", first_name: 'Ad', last_name: 'Min',
                            password: 'Pass1234!', role: 'admin', status: 'active')
    end
    let(:ctx) { Guide::AppContext.new(user: user, company: company) }

    before do
      allow_any_instance_of(ModuleAccessService).to receive(:has_module?).and_return(true)
      Setting.set('Company', company.id, 'communications', {
        'sms' => { 'provider' => 'twilio', 'fromNumber' => '+15555550100', 'isEnabled' => true,
                   'twilioAccountSid' => 'ACSECRETSID', 'twilioAuthToken' => 'TWILIOSECRET' },
        'email' => { 'provider' => 'smtp', 'fromEmail' => 'sales@example.com', 'smtpPassword' => 'SMTPSECRET',
                     'awsSecretAccessKey' => 'AWSSECRET' }
      })
    end

    it 'reads every module without a lookup failing' do
      skipped = []
      allow(Rails.logger).to receive(:info).and_wrap_original do |orig, msg|
        skipped << msg if msg.to_s.include?('skipped a fact')
        orig.call(msg)
      end

      described_class.keys.each do |key|
        out = described_class.new(ctx).call(key)
        expect(out).not_to have_key(:error), "#{key}: #{out}"
      end
      expect(skipped).to be_empty, skipped.join("\n")
    end

    it 'never hands over a password, key or token' do
      text = described_class.keys.map { |k| described_class.new(ctx).call(k) }.to_json
      %w[TWILIOSECRET ACSECRETSID SMTPSECRET AWSSECRET].each { |secret| expect(text).not_to include(secret) }
      expect(text).to include('+15555550100').and include('sales@example.com')
    end

    it 'says plainly what is not offered' do
      expect(described_class.new(ctx).call('inventory.lot_map')[:not_offered]).to include('Not offered')
    end

    it 'explains commission plans in plain words, with the plan this person gets' do
      plan = company.commission_plans.create!(name: 'Sales Team', is_active: true, is_default: true)
      company.commission_components.create!(name: 'Agent', component_type: 'percent_of_gross', gross_type: 'house_profit',
                                            rate: 0.2, commission_plan: plan, is_active: true, applies_to_role: 'primary_salesperson')
      company.commission_plans.create!(name: 'Old Plan', is_active: false)

      out = described_class.new(ctx).call('management.commissions')
      expect(out[:your_plan]).to eq('Sales Team')
      expect(out[:plans].map { |p| p[:name] }).to eq(['Sales Team'])
      expect(out[:plans].first[:components].first[:pays]).to be_present
      expect(out[:inactive_or_expired_plans]).to eq(1)
      expect(out[:commission_becomes_payable]).to be_present
    end

    it 'reads the books setup' do
      AccountingSettings.for_company(company) || AccountingSettings.create!(company: company)
      out = described_class.new(ctx).call('finance.accounting')
      expect(out[:posts_by_itself]).to include(invoices: 'yes')
      expect(out[:posts_to_these_accounts]).to have_key(:customer_deposits)
    end
  end

  context 'with roles' do
    before { seed_rbac! }

    let(:company) { connector_company }

    it 'tells someone without plan read that their role does not include it, and shows no plan' do
      CommissionPlan.create!(company: company, name: 'Secret Plan', is_active: true) rescue nil
      user = connector_user(company, { 'leads' => %w[read] })
      allow_any_instance_of(ModuleAccessService).to receive(:has_module?).and_return(true)
      out = described_class.new(Guide::AppContext.new(user: user, company: company)).call('management.commissions')
      expect(out[:not_allowed]).to include('Your role does not include')
      expect(out.to_json).not_to include('Secret Plan')
    end

    it 'says when a module is not on the plan' do
      user = connector_user(company, { 'commission_plans' => %w[read] })
      allow_any_instance_of(ModuleAccessService).to receive(:has_module?).and_return(false)
      out = described_class.new(Guide::AppContext.new(user: user, company: company)).call('management.commissions')
      expect(out[:on_plan]).to be(false)
    end
  end
end
