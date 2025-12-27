# frozen_string_literal: true

# QuickBooks Background Jobs
# These handle automated sync, token refresh, webhook processing, cleanup, and monitoring

module QuickbooksJobs
  class TokenRefreshJob < ApplicationJob
    queue_as :default
    
    def perform
      Company.with_expired_quickbooks_tokens.find_each do |company|
        result = company.refresh_quickbooks_token!
        
        if result[:success]
          Rails.logger.info("Refreshed QB token for company #{company.id}")
        else
          Rails.logger.error("Failed to refresh QB token for company #{company.id}: #{result[:error]}")
        end
      end
    end
  end

  class AutoSyncJob < ApplicationJob
    queue_as :default
    
    def perform(company_id)
      company = Company.find(company_id)
      return unless company.quickbooks_sync_enabled?
      
      settings = company.resolved_quickbooks_settings
      return unless settings[:auto_sync]
      
      sync_service = QuickbooksSyncService.new(company)
      result = sync_service.incremental_sync
      
      if result[:success]
        Rails.logger.info("Auto-sync completed for company #{company.id}")
      else
        Rails.logger.error("Auto-sync failed for company #{company.id}: #{result[:error]}")
      end
    end
  end

  class WebhookProcessorJob < ApplicationJob
    queue_as :default
    
    def perform
      QuickbooksWebhook.pending.limit(50).find_each do |webhook|
        webhook.process!
      end
    end
  end

  class CleanupJob < ApplicationJob
    queue_as :default
    
    def perform
      deleted_logs = QuickbooksSyncLog.where('created_at < ?', 30.days.ago).delete_all
      deleted_webhooks = QuickbooksWebhook.cleanup_old(30)
      
      QuickbooksSyncMapping.with_errors.where('sync_error_count > 10').update_all(sync_status: 'disabled')
      
      Rails.logger.info("QB Cleanup: Deleted #{deleted_logs} logs, #{deleted_webhooks} webhooks")
    end
  end

  class SyncHealthJob < ApplicationJob
    queue_as :default
    
    def perform
      companies = Company.with_quickbooks_enabled
      
      companies.find_each do |company|
        stats = company.quickbooks_sync_stats(1.hour)
        
        if stats[:failed] > 10 && stats[:success_rate] < 50
          Rails.logger.warn("QB health check: Company #{company.id} has #{stats[:failed]} failures (#{stats[:success_rate]}% success rate)")
        end
        
        if company.quickbooks_last_sync_at && company.quickbooks_last_sync_at < 24.hours.ago
          Rails.logger.warn("QB health check: Company #{company.id} hasn't synced in 24 hours")
        end
      end
    end
  end
end
