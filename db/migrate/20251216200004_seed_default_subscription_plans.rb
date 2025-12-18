# frozen_string_literal: true

class SeedDefaultSubscriptionPlans < ActiveRecord::Migration[8.0]
  def up
    # Load the seed file
    load Rails.root.join('db/seeds/subscription_plans.rb')
  end

  def down
    # Remove seeded data (optional - be careful with this in production)
    # SubscriptionPlanModule.delete_all
    # SubscriptionPlan.where(name: %w[starter professional enterprise]).destroy_all
    puts "Note: Subscription plan data not removed. Remove manually if needed."
  end
end
