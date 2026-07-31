class CampaignSchedulerJob < ApplicationJob
  queue_as :default

  def perform
    promote_scheduled_to_running
    enroll_running_without_enrollments
    enroll_running_dynamic
    dispatch_due_enrollments
    finalize_completed_campaigns
  end

  private

  def promote_scheduled_to_running
    Campaign.where(status: 'scheduled').where('scheduled_at <= ?', Time.current).find_each do |c|
      c.update!(status: 'running')
      if defined?(WebhookService)
        WebhookService.fire(company_id: c.company_id, event: 'campaign.started', payload: { campaign_id: c.id })
      end
      CampaignAudienceEnrollerJob.perform_later(c.id)
    end
  end

  # Static campaigns only — dynamic ones are swept unconditionally below, so
  # leaving them here too would just enqueue the same job twice per tick.
  def enroll_running_without_enrollments
    Campaign.running
            .where.not(audience_mode: 'dynamic')
            .left_joins(:campaign_enrollments)
            .group('campaigns.id')
            .having('COUNT(campaign_enrollments.id) = 0')
            .find_each do |c|
      CampaignAudienceEnrollerJob.perform_later(c.id)
    end
  end

  # A dynamic audience means "whoever matches the filter, whenever they match" —
  # but the only paths that ever re-enrolled were the zero-enrollment sweep above
  # and TagAssignment's on-tag refresh. So editing a running campaign's audience
  # (adding a tag to the filter, widening a condition) moved the estimated_count
  # on screen and enrolled nobody: the new matches got no enrollment row and
  # therefore no email, while the UI showed them as recipients. Same gap for a
  # record that starts matching for any non-tag reason (new lead, status change).
  # Sweeping every running dynamic campaign each tick closes both. AudienceEnroller
  # seeds its dedupe set from existing enrollment snapshots, so already-enrolled
  # recipients are skipped in memory — a re-run over an unchanged audience costs
  # one scope query, not one lookup per member.
  def enroll_running_dynamic
    Campaign.running.where(audience_mode: 'dynamic').find_each do |c|
      CampaignAudienceEnrollerJob.perform_later(c.id)
    end
  end

  def dispatch_due_enrollments
    CampaignEnrollment.due_for_send.find_in_batches(batch_size: 200) do |batch|
      batch.each { |e| ProcessCampaignSendJob.perform_later(e.id) }
    end
  end

  def finalize_completed_campaigns
    Campaign.running.find_each do |c|
      total = c.campaign_enrollments.count
      next if total.zero?
      remaining = c.campaign_enrollments.where(status: %w[pending active]).count
      next if remaining.positive?

      # Recurring-digest campaigns cycle forever — the user's INTENT is
      # "keep sending". Even when recurrence_cron is blank (older AI-generated
      # rows before the accept path persisted cadence), auto-heal by
      # applying the safe weekly-Mon-9AM default and keep the campaign
      # scheduled for the next boundary. Never mark a recurring_digest as
      # completed here; a rep asked "recurring campaigns should never be
      # complete" and they're right.
      if c.campaign_type == 'recurring_digest'
        if c.recurrence_cron.blank?
          Rails.logger.warn "[CampaignSchedulerJob] Campaign #{c.id} is recurring_digest but recurrence_cron is blank — applying weekly-Mon-9AM default"
          c.update_column(:recurrence_cron, '0 9 * * MON')
          c.reload
        end
        next_at = c.next_recurrence_at
        if next_at.nil?
          # Fugit couldn't parse the cron even after the auto-heal (malformed
          # custom expression from a manual edit). Keep the campaign running
          # rather than finalizing so an admin can fix the cron without
          # losing the audience — no cycle happens until the cron parses.
          Rails.logger.warn "[CampaignSchedulerJob] Campaign #{c.id} recurrence_cron did not parse; leaving in running state for admin to fix"
          next
        end
        c.update!(
          status: 'scheduled',
          scheduled_at: next_at,
          audience_snapshot_at: nil
        )
        if defined?(WebhookService)
          WebhookService.fire(company_id: c.company_id, event: 'campaign.cycle_completed', payload: { campaign_id: c.id, next_send_at: next_at.iso8601 })
        end
        next
      end

      c.update!(status: 'completed', completed_at: Time.current)
      if defined?(WebhookService)
        WebhookService.fire(company_id: c.company_id, event: 'campaign.completed', payload: { campaign_id: c.id })
      end
    end
  end
end
