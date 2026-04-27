class AddAiCreditsToSubscriptionPlansAndTenants < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:subscription_plans, :max_ai_credits)
      add_column :subscription_plans, :max_ai_credits, :integer, default: 50, null: false
    end

    unless column_exists?(:tenant_subscriptions, :ai_credits_override)
      add_column :tenant_subscriptions, :ai_credits_override, :integer
    end
  end
end
