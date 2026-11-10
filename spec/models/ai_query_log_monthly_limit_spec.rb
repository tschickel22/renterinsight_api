# frozen_string_literal: true

require 'rails_helper'

# The monthly AI allowance. The add-on check used to call a Company method that
# does not exist, so every company without a saved limit got 0 and saw "AI reporting
# is not enabled" even with the add-on on (Easy Homesource, 2026-11-10).
RSpec.describe AiQueryLog, '.monthly_limit_for' do
  let(:company) { create(:company) }

  def enable_ai_addon(enabled = true)
    TenantModuleOverride.create!(company: company, module_key: 'management_ai_reports', is_enabled: enabled)
  end

  it 'gives 100 a month when the add-on is on and no limit is saved' do
    enable_ai_addon
    expect(described_class.monthly_limit_for(company)).to eq(100)
  end

  it 'gives 0 when the add-on is off and no limit is saved' do
    enable_ai_addon(false)
    expect(described_class.monthly_limit_for(company)).to eq(0)
  end

  it 'uses a saved company limit' do
    Setting.set('Company', company.id, 'ai_report_queries_monthly_limit', '250')
    expect(described_class.monthly_limit_for(company)).to eq(250)
  end

  it 'treats a saved company limit of 0 as off, even with the add-on and a platform limit' do
    enable_ai_addon
    Setting.set('Platform', 0, 'ai_report_queries_monthly_limit', '300')
    Setting.set('Company', company.id, 'ai_report_queries_monthly_limit', '0')
    expect(described_class.monthly_limit_for(company)).to eq(0)
  end

  it 'gives platform admins effectively unlimited' do
    Setting.set('Company', company.id, 'ai_report_queries_monthly_limit', '0')
    admin = Struct.new(:role).new('platform_admin')
    expect(described_class.monthly_limit_for(company, user: admin)).to eq(999)
  end
end
