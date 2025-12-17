# frozen_string_literal: true

# Seed default subscription plans
# Run with: bin/rails db:seed:subscription_plans
# Or: bin/rails runner "load 'db/seeds/subscription_plans.rb'"

puts "Seeding subscription plans..."

# Define the three default plans
plans_data = [
  {
    name: 'starter',
    display_name: 'Starter',
    description: 'Perfect for small dealerships just getting started. Core CRM and inventory features to manage your business.',
    category: 'starter',
    zoho_plan_code: 'DMS_STARTER',
    pricing_monthly: 49,
    pricing_annual: 490,
    max_users: 5,
    max_storage_gb: 10,
    max_locations: 1,
    max_api_calls: 5000,
    trial_enabled: true,
    trial_days: 14,
    setup_fee: 0,
    is_active: true,
    is_popular: false,
    position: 1,
    modules: PlatformModule.template_modules(:starter)
  },
  {
    name: 'professional',
    display_name: 'Professional',
    description: 'For growing dealerships that need full CRM, inventory, finance, and service capabilities.',
    category: 'professional',
    zoho_plan_code: 'DMS_PROFESSIONAL',
    pricing_monthly: 149,
    pricing_annual: 1490,
    max_users: 25,
    max_storage_gb: 100,
    max_locations: 5,
    max_api_calls: 25000,
    trial_enabled: true,
    trial_days: 14,
    setup_fee: 0,
    is_active: true,
    is_popular: true,
    position: 2,
    modules: PlatformModule.template_modules(:professional)
  },
  {
    name: 'enterprise',
    display_name: 'Enterprise',
    description: 'Full platform access for large dealership groups with unlimited users, locations, and all features.',
    category: 'enterprise',
    zoho_plan_code: 'DMS_ENTERPRISE',
    pricing_monthly: 399,
    pricing_annual: 3990,
    max_users: 999,
    max_storage_gb: 1000,
    max_locations: 99,
    max_api_calls: 100000,
    trial_enabled: false,
    trial_days: 0,
    setup_fee: 500,
    is_active: true,
    is_popular: false,
    position: 3,
    modules: PlatformModule.template_modules(:enterprise)
  }
]

plans_data.each do |plan_data|
  modules = plan_data.delete(:modules)
  
  plan = SubscriptionPlan.find_or_initialize_by(name: plan_data[:name])
  plan.assign_attributes(plan_data)
  
  if plan.save
    puts "  ✓ Created/Updated plan: #{plan.display_name}"
    
    # Set up modules for this plan
    PlatformModule.all_keys.each do |module_key|
      mod = plan.subscription_plan_modules.find_or_initialize_by(module_key: module_key)
      mod.is_enabled = modules.include?(module_key)
      mod.save!
    end
    
    enabled_count = plan.subscription_plan_modules.where(is_enabled: true).count
    puts "    → #{enabled_count} modules enabled"
  else
    puts "  ✗ Failed to create plan #{plan_data[:name]}: #{plan.errors.full_messages.join(', ')}"
  end
end

puts ""
puts "Subscription plans seeding complete!"
puts "  Total plans: #{SubscriptionPlan.count}"
puts ""

# Display summary
SubscriptionPlan.ordered.each do |plan|
  enabled = plan.subscription_plan_modules.where(is_enabled: true).count
  total = plan.subscription_plan_modules.count
  puts "  #{plan.display_name}: $#{plan.pricing_monthly}/mo, #{plan.max_users} users, #{enabled}/#{total} modules"
end
