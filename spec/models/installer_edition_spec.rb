# frozen_string_literal: true

require 'rails_helper'

# E68 step 7: the Installer Edition plan and the installer industry.
RSpec.describe 'Installer Edition' do
  let(:plan) do
    SubscriptionPlan.find_by(name: 'installer') ||
      SubscriptionPlan.create!(name: 'installer', display_name: 'Installer Edition', category: 'professional',
                               pricing_monthly: 399, pricing_annual: 3990).tap { |p| p.set_enabled_modules(PlatformModule.template_modules(:installer)) }
  end

  it 'gives an install company jobs, crews, billing and books, and nothing for selling homes' do
    keys = PlatformModule.template_modules(:installer)
    expect(keys).to include('management.projects', 'management.contractors', 'finance.accounting', 'finance.invoices', 'crm.accounts')
    expect(keys).not_to include('crm.prospecting', 'crm.deals', 'inventory.vehicles', 'marketing.website', 'management.linked_companies', 'admin.platform')
    expect(keys - PlatformModule.all_keys).to be_empty
  end

  it 'turns those modules on for a company on the plan' do
    company = create(:company, industry: 'installer')
    TenantSubscription.create!(company: company, subscription_plan: plan, status: 'active')
    access = ModuleAccessService.new(company.reload)
    expect(access.has_module?('management.projects')).to be(true)
    expect(access.has_module?('finance.accounting')).to be(true)
    expect(access.has_module?('crm.deals')).to be(false)
    expect(plan.effective_monthly_price.to_f).to eq(399.0)
  end

  it 'calls projects jobs and keeps the home words' do
    company = create(:company, industry: 'installer')
    labels = company.resolved_labels
    expect(labels).to include('project' => 'Job', 'projects' => 'Jobs', 'linked_companies' => 'Linked Dealers', 'vehicle' => 'Home')
    expect(create(:company, industry: 'manufactured_housing').resolved_labels['projects']).to eq('Projects')
    expect(Company::INDUSTRY_OPTIONS['installer']).to eq('Home Installer')
  end

  it 'seeds the chart of accounts for a new installer, without the home-selling allowances' do
    expect(CompanyAllowanceDefault).not_to receive(:seed_defaults)
    company = create(:company, industry: 'installer')
    expect(ChartOfAccount.where(company_id: company.id).count).to be > 20
  end
end
