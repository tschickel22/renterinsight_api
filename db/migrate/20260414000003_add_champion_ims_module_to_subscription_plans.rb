# frozen_string_literal: true

# Enables the 'inventory.champion_ims' module for existing enterprise-tier
# subscription plans. The module itself is registered in the
# PlatformModule::MODULES constant (a code change, not a DB change).
#
# This data migration ensures that companies who already have an enterprise
# plan get the new module without requiring a manual DB touch-up in staging
# or production.
#
# Starter and Professional tiers do NOT get Champion IMS by default - it
# remains available via per-tenant override if a customer requests it.
class AddChampionImsModuleToSubscriptionPlans < ActiveRecord::Migration[8.0]
  MODULE_KEY = 'inventory.champion_ims'

  def up
    return unless defined?(SubscriptionPlan) && defined?(SubscriptionPlanModule)

    # Find all enterprise-tier plans. The subscription_plans table uses
    # `category` (values: starter/professional/enterprise) plus `name` as
    # an internal key. Match on both to be resilient to deployment differences.
    enterprise_plans = SubscriptionPlan.where(
      'LOWER(COALESCE(category, name)) LIKE ?', '%enterprise%'
    )

    enterprise_plans.find_each do |plan|
      existing = SubscriptionPlanModule.find_by(
        subscription_plan_id: plan.id,
        module_key: MODULE_KEY
      )
      next if existing.present?

      SubscriptionPlanModule.create!(
        subscription_plan_id: plan.id,
        module_key: MODULE_KEY,
        is_enabled: true,
        config: {}
      )
      say "Enabled #{MODULE_KEY} on plan ##{plan.id} (#{plan.name})"
    end
  rescue NameError => e
    say "Skipping #{MODULE_KEY} seed: #{e.message}"
  end

  def down
    return unless defined?(SubscriptionPlanModule)
    SubscriptionPlanModule.where(module_key: MODULE_KEY).delete_all
  end
end
