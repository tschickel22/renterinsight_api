# frozen_string_literal: true

# Migration to convert existing subscription_tier values on companies
# to proper TenantSubscription records with the new subscription system

class MigrateExistingSubscriptionTiers < ActiveRecord::Migration[7.1]
  def up
    # Only run if we have the new tables
    return unless table_exists?(:subscription_plans) && table_exists?(:tenant_subscriptions)
    
    # Get plan mapping
    plans = {}
    execute("SELECT id, name, category FROM subscription_plans").each do |row|
      # Handle both array (PG) and hash (SQLite) results
      if row.is_a?(Hash)
        plans[row['category']] = row['id']
        plans[row['name']] = row['id']
      else
        plans[row[2]] = row[0]  # category -> id
        plans[row[1]] = row[0]  # name -> id
      end
    end
    
    return if plans.empty?
    
    # Find companies without subscriptions
    companies_sql = <<-SQL
      SELECT c.id, c.name, c.subscription_tier, c.status, c.trial_ends_at
      FROM companies c
      LEFT JOIN tenant_subscriptions ts ON ts.company_id = c.id
      WHERE ts.id IS NULL
        AND c.subscription_tier IS NOT NULL
        AND c.subscription_tier != ''
    SQL
    
    companies = execute(companies_sql)
    
    companies.each do |row|
      # Handle both array (PG) and hash (SQLite) results
      if row.is_a?(Hash)
        company_id = row['id']
        tier = row['subscription_tier']
        status = row['status']
        trial_ends_at = row['trial_ends_at']
      else
        company_id = row[0]
        tier = row[2]
        status = row[3]
        trial_ends_at = row[4]
      end
      
      # Map tier to plan
      plan_id = plans[tier] || plans['starter'] || plans.values.first
      next unless plan_id
      
      # Determine subscription status
      sub_status = case status&.downcase
                   when 'trial' then 'trial'
                   when 'suspended' then 'suspended'
                   when 'cancelled' then 'cancelled'
                   else 'active'
                   end
      
      # Create subscription - use strftime for date formatting (Rails 7+ compatible)
      now = Time.current.strftime('%Y-%m-%d %H:%M:%S')
      period_end = (Time.current + 1.month).strftime('%Y-%m-%d %H:%M:%S')
      
      insert_sql = <<-SQL
        INSERT INTO tenant_subscriptions 
        (company_id, subscription_plan_id, status, billing_cycle, 
         current_period_start, current_period_end, trial_ends_at,
         current_users, current_storage_gb, current_locations,
         created_at, updated_at)
        VALUES 
        (#{company_id}, #{plan_id}, '#{sub_status}', 'monthly',
         '#{now}', '#{period_end}', #{trial_ends_at ? "'#{trial_ends_at}'" : 'NULL'},
         0, 0, 0,
         '#{now}', '#{now}')
      SQL
      
      begin
        execute(insert_sql)
        puts "Created subscription for company #{company_id} (tier: #{tier} -> plan: #{plan_id})"
      rescue => e
        puts "Failed to create subscription for company #{company_id}: #{e.message}"
      end
    end
  end

  def down
    # Remove subscriptions created by this migration
    # We can't easily identify which ones, so just leave them
    puts "Note: TenantSubscription records created by migration are not automatically removed"
  end
end
