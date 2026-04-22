# frozen_string_literal: true

# Nightly job. For every company with an active Facebook integration that has
# an ad_account_id stored, pulls Meta campaign + insights data and refreshes
# ROI metrics on local ad_campaigns rows.
class SyncAdSpendJob < ApplicationJob
  queue_as :default

  def perform
    synced = 0
    failed = 0

    company_ids = FacebookIntegration.active.distinct.pluck(:company_id)

    Company.where(id: company_ids).find_each do |company|
      begin
        result = MetaAdSpendService.sync_for_company(company)
        if result[:synced].to_i.positive?
          company.ad_campaigns.active.find_each { |c| safely_recalc(c) }
        end
        synced += 1
      rescue => e
        failed += 1
        Rails.logger.error "[SyncAdSpendJob] company=#{company.id} failed: #{e.class}: #{e.message}"
      end
    end

    Rails.logger.info "[SyncAdSpendJob] synced=#{synced} failed=#{failed}"
  end

  private

  def safely_recalc(campaign)
    campaign.calculate_roi!
  rescue => e
    Rails.logger.error "[SyncAdSpendJob] campaign=#{campaign.id} roi recalc failed: #{e.message}"
  end
end
