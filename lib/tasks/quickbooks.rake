# frozen_string_literal: true

namespace :quickbooks do
  desc 'Run incremental sync for all companies with QuickBooks enabled'
  task auto_sync: :environment do
    puts "[#{Time.current}] Starting QuickBooks auto-sync"
    
    companies = Company.with_quickbooks_enabled
    
    if companies.none?
      puts "No companies with QuickBooks enabled"
      next
    end
    
    puts "Found #{companies.count} companies with QuickBooks enabled"
    
    companies.each do |company|
      begin
        puts "\n[Company ##{company.id}] #{company.name}"
        QuickbooksJobs::AutoSyncJob.perform_now(company.id)
        puts "[Company ##{company.id}] ✅ Sync completed"
      rescue => e
        puts "[Company ##{company.id}] ❌ Error: #{e.message}"
        Rails.logger.error "QB Auto-sync failed for Company ##{company.id}: #{e.message}"
      end
    end
    
    puts "\n[#{Time.current}] QuickBooks auto-sync complete"
  end
  
  desc 'Refresh expired QuickBooks tokens'
  task refresh_tokens: :environment do
    puts "[#{Time.current}] Starting token refresh"
    QuickbooksJobs::TokenRefreshJob.perform_now
    puts "[#{Time.current}] Token refresh complete"
  end
  
  desc 'Clean up old QuickBooks sync logs and webhooks'
  task cleanup: :environment do
    puts "[#{Time.current}] Starting cleanup"
    QuickbooksJobs::CleanupJob.perform_now
    puts "[#{Time.current}] Cleanup complete"
  end
  
  desc 'Check QuickBooks sync health'
  task health_check: :environment do
    puts "[#{Time.current}] Starting health check"
    QuickbooksJobs::SyncHealthJob.perform_now
    puts "[#{Time.current}] Health check complete"
  end
end
