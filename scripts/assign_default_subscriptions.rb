#!/usr/bin/env ruby
# Assign default subscription plans to companies that don't have them
# Usage: bin/rails runner scripts/assign_default_subscriptions.rb

puts "\nAssigning default subscriptions to companies without TenantSubscription records..."
puts "="*80

# Find companies without tenant_subscription
companies_without_sub = Company.left_outer_joins(:tenant_subscription)
                               .where(tenant_subscriptions: { id: nil })

if companies_without_sub.empty?
  puts "✅ All companies already have subscription records!"
  exit
end

puts "Found #{companies_without_sub.count} companies without subscriptions:\n"

# Try to find a default plan
default_plan = SubscriptionPlan.find_by(name: 'starter') || 
               SubscriptionPlan.find_by(category: 'starter') ||
               SubscriptionPlan.active.first

unless default_plan
  puts "❌ ERROR: No subscription plans found in database!"
  puts "   Please create at least one subscription plan in Platform Admin first."
  exit
end

puts "Using plan: #{default_plan.display_name} (ID: #{default_plan.id})"
puts "Category: #{default_plan.category}"
puts "\nCreating subscriptions...\n"

companies_without_sub.each do |company|
  begin
    # Create tenant subscription
    subscription = TenantSubscription.create!(
      company: company,
      subscription_plan: default_plan,
      billing_cycle: 'monthly',
      status: 'active',
      current_period_start: Time.current,
      current_period_end: 1.month.from_now
    )
    
    # Update company's legacy subscription_tier field
    company.update_columns(subscription_tier: default_plan.category)
    
    puts "✅ #{company.name} (ID: #{company.id})"
  rescue => e
    puts "❌ #{company.name} - ERROR: #{e.message}"
  end
end

puts "\n" + "="*80
puts "✅ Done! Run diagnostic again to verify:"
puts "   bin/rails runner scripts/diagnose_modules.rb"
