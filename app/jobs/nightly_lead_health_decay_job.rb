# frozen_string_literal: true

# Recalculates health_score for all active (non-converted, non-deleted) leads.
# Scheduled to run nightly.
class NightlyLeadHealthDecayJob < ApplicationJob
  queue_as :low

  BATCH_SIZE = 500

  def perform
    scope = Lead.where(is_converted: [false, nil])

    processed = 0
    failed    = 0

    scope.find_each(batch_size: BATCH_SIZE) do |lead|
      begin
        LeadHealthScoreService.new(lead).save!
        processed += 1
      rescue => e
        failed += 1
        Rails.logger.error "[NightlyLeadHealthDecayJob] lead=#{lead.id} failed: #{e.message}"
      end
    end

    Rails.logger.info "[NightlyLeadHealthDecayJob] processed=#{processed} failed=#{failed}"
  end
end
