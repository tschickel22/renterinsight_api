module Campaigns
  class AudienceEnroller
    def initialize(campaign:)
      @campaign = campaign
      @audience = @campaign.campaign_audience
    end

    def enroll_all
      return 0 unless @audience

      base = @audience.compute_matches
      filter_tree = @audience.filter_tree
      exclude_tree = @audience.exclude_filter_tree

      first_step = @campaign.campaign_steps.active.ordered.first
      first_wait_seconds = ((first_step&.wait_days || 0) * 86400) + ((first_step&.wait_hours || 0) * 3600)
      next_send_at = Time.current + first_wait_seconds.seconds

      enrolled = 0
      base.find_each do |record|
        next unless WorkflowEngine::ConditionEvaluator.evaluate(filter_tree, record)
        next if exclude_tree.present? && WorkflowEngine::ConditionEvaluator.evaluate(exclude_tree, record)

        contact_value = if @campaign.email_channel?
                          record.try(:email)
                        else
                          normalize_phone(record.try(:phone))
                        end
        next if contact_value.blank?
        next if CampaignSuppression.suppressed?(@campaign.company_id, contact_value)

        attrs = {
          company_id: @campaign.company_id, campaign_id: @campaign.id,
          recipient_type: @audience.source_type, recipient_id: record.id,
          status: 'pending', current_step_index: 0,
          next_send_at: next_send_at
        }
        if @campaign.email_channel?
          attrs[:email_address_snapshot] = contact_value
        else
          attrs[:sms_phone_snapshot] = contact_value
        end

        existing = CampaignEnrollment.find_by(
          campaign_id: @campaign.id,
          recipient_type: attrs[:recipient_type],
          recipient_id: attrs[:recipient_id]
        )
        next if existing

        enrollment = CampaignEnrollment.create(attrs)
        next unless enrollment.persisted?

        enrolled += 1
        CampaignEvent.create!(
          company_id: @campaign.company_id, campaign_id: @campaign.id,
          campaign_enrollment_id: enrollment.id,
          event_type: 'enrolled', occurred_at: Time.current,
          payload: { recipient_type: enrollment.recipient_type, recipient_id: enrollment.recipient_id }
        )
        if defined?(WebhookService)
          WebhookService.fire(
            company_id: @campaign.company_id, event: 'campaign.enrollment_created',
            payload: { campaign_id: @campaign.id, enrollment_id: enrollment.id,
                       recipient_type: enrollment.recipient_type, recipient_id: enrollment.recipient_id }
          )
        end
      end

      if @campaign.audience_mode == 'static' && @campaign.audience_snapshot_at.nil?
        @campaign.update_column(:audience_snapshot_at, Time.current)
      end

      enrolled
    end

    private

    def normalize_phone(phone)
      return nil if phone.blank?
      digits = phone.to_s.gsub(/\D/, '')
      return nil if digits.blank?
      if digits.length == 10
        "+1#{digits}"
      elsif digits.length == 11 && digits.start_with?('1')
        "+#{digits}"
      else
        "+#{digits}"
      end
    end
  end
end
