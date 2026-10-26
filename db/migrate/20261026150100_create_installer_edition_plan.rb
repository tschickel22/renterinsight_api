# frozen_string_literal: true

# E68 step 7: the Installer Edition, $399 a month, for an install company that
# runs its own jobs, crews and books (PlatformModule::PLAN_TEMPLATES[:installer]).
# Plans are data, so every environment gets it here; platform admins can
# change the price or modules afterwards and a rerun leaves an existing plan alone.
class CreateInstallerEditionPlan < ActiveRecord::Migration[8.0]
  def up
    return if SubscriptionPlan.exists?(name: 'installer')

    plan = SubscriptionPlan.create!(
      name: 'installer', display_name: 'Installer Edition', category: 'professional',
      description: 'For install companies: jobs from linked dealers and your own, crews and subcontractors, bids, ' \
                   'billing and your own books.',
      zoho_plan_code: 'DMS_INSTALLER', pricing_monthly: 399, pricing_annual: 3990, currency: 'USD',
      billing_model: 'flat', max_users: 25, max_storage_gb: 100, max_locations: 5, max_api_calls: 25_000,
      trial_enabled: false, trial_days: 0, setup_fee: 0, is_active: true, is_popular: false,
      position: (SubscriptionPlan.maximum(:position) || 0) + 1
    )
    plan.set_enabled_modules(PlatformModule.template_modules(:installer))
  end

  def down
    SubscriptionPlan.find_by(name: 'installer', zoho_plan_code: 'DMS_INSTALLER')&.then do |plan|
      plan.destroy if plan.tenant_subscriptions.none?
    end
  end
end
