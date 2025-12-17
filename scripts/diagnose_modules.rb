#!/usr/bin/env ruby
# Run with: bin/rails runner scripts/diagnose_modules.rb

puts "\n" + "="*80
puts "MODULE ACCESS DIAGNOSTIC REPORT"
puts "="*80

Company.all.each do |company|
  puts "\n#{'-'*80}"
  puts "Company: #{company.name} (ID: #{company.id})"
  puts "Subscription Tier: #{company.subscription_tier || 'None'}"
  
  # Check tenant_subscription
  if company.tenant_subscription.present?
    sub = company.tenant_subscription
    puts "✅ Has TenantSubscription (ID: #{sub.id})"
    puts "   Status: #{sub.status}"
    puts "   Billing: #{sub.billing_cycle}"
    
    if sub.subscription_plan.present?
      plan = sub.subscription_plan
      puts "✅ Has SubscriptionPlan (ID: #{plan.id})"
      puts "   Plan Name: #{plan.display_name}"
      puts "   Category: #{plan.category}"
      
      # Check subscription_plan_modules
      plan_modules = plan.subscription_plan_modules
      if plan_modules.any?
        enabled_count = plan_modules.where(is_enabled: true).count
        total_count = plan_modules.count
        puts "✅ Has #{enabled_count}/#{total_count} modules enabled"
        
        if enabled_count > 0
          puts "\n   Enabled Modules:"
          plan_modules.where(is_enabled: true).limit(10).each do |mod|
            puts "   - #{mod.module_key}"
          end
          puts "   ... (#{enabled_count} total)" if enabled_count > 10
        end
      else
        puts "❌ NO subscription_plan_modules records found!"
        puts "   This means the plan was created but modules weren't set up"
      end
    else
      puts "❌ TenantSubscription exists but has NO subscription_plan_id"
    end
  else
    puts "❌ NO TenantSubscription record"
    puts "   Using legacy fallback: PlatformModule.template_modules(:#{company.subscription_tier || 'starter'})"
    
    legacy_modules = PlatformModule.template_modules(company.subscription_tier&.to_sym || :starter)
    puts "   Legacy would provide #{legacy_modules.count} modules"
  end
  
  # Check what module_access service actually returns
  puts "\n   🔍 ModuleAccessService check:"
  begin
    enabled = company.module_access.enabled_modules
    puts "   Returns #{enabled.count} enabled modules"
    
    if enabled.count > 30
      puts "   ⚠️  WARNING: Too many modules (#{enabled.count}) - likely using legacy fallback"
    elsif enabled.count == 0
      puts "   ⚠️  WARNING: No modules enabled - plan has no modules configured"
    end
  rescue => e
    puts "   ❌ ERROR: #{e.message}"
  end
end

puts "\n" + "="*80
puts "SUBSCRIPTION PLANS IN DATABASE:"
puts "="*80

SubscriptionPlan.all.each do |plan|
  puts "\nPlan: #{plan.display_name} (ID: #{plan.id})"
  puts "Category: #{plan.category}"
  puts "Is Active: #{plan.is_active}"
  
  plan_modules = plan.subscription_plan_modules
  if plan_modules.any?
    enabled_count = plan_modules.where(is_enabled: true).count
    puts "Modules: #{enabled_count}/#{plan_modules.count} enabled"
  else
    puts "⚠️  NO modules configured for this plan!"
  end
  
  # Show companies using this plan
  using_companies = TenantSubscription.where(subscription_plan_id: plan.id).includes(:company)
  if using_companies.any?
    puts "Used by #{using_companies.count} companies:"
    using_companies.each do |sub|
      puts "  - #{sub.company.name}"
    end
  else
    puts "Not used by any companies"
  end
end

puts "\n" + "="*80
puts "RECOMMENDATIONS:"
puts "="*80

# Check for companies without tenant_subscription
companies_without_sub = Company.left_outer_joins(:tenant_subscription)
                               .where(tenant_subscriptions: { id: nil })

if companies_without_sub.any?
  puts "\n⚠️  #{companies_without_sub.count} companies are missing TenantSubscription records:"
  companies_without_sub.each do |c|
    puts "   - #{c.name} (ID: #{c.id})"
  end
  puts "\n   Fix: Assign subscription plans to these companies in Platform Admin"
  puts "   Or run: bin/rails runner scripts/assign_default_subscriptions.rb"
end

# Check for plans without modules
plans_without_modules = SubscriptionPlan.left_outer_joins(:subscription_plan_modules)
                                       .group('subscription_plans.id')
                                       .having('COUNT(subscription_plan_modules.id) = 0')

if plans_without_modules.any?
  puts "\n⚠️  #{plans_without_modules.count} subscription plans have NO modules configured:"
  plans_without_modules.each do |p|
    puts "   - #{p.display_name} (ID: #{p.id})"
  end
  puts "\n   Fix: Edit these plans in Platform Admin → Subscription Plans and select modules"
  puts "   Or run: bin/rails runner \"scripts/fix_plan_modules.rb PLAN_ID\""
end

puts "\n" + "="*80 + "\n"
