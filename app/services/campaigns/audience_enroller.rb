module Campaigns
  class AudienceEnroller
    def initialize(campaign:)
      @campaign = campaign
      @audience = @campaign.campaign_audience
    end

    def enroll_all
      return 0 unless @audience

      base = audience_scope

      first_step = @campaign.campaign_steps.active.ordered.first
      first_wait_seconds = ((first_step&.wait_days || 0) * 86400) + ((first_step&.wait_hours || 0) * 3600)
      next_send_at = Time.current + first_wait_seconds.seconds

      enrolled = 0
      base.find_each do |record|
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

    # The exact audience set — the SAME Audiences::FilterCompiler the count/preview/members
    # use — so who gets enrolled matches what the audience screen shows. This applies the
    # filter AND every exclusion (exclude_filter_tree, manual_exclude_ids, active-campaign
    # and active-nurture excludes), which the old per-record ConditionEvaluator path skipped.
    # SMS opt-in compliance is layered on top for SMS campaigns.
    def audience_scope
      scope = Audiences::FilterCompiler.new(
        company: @campaign.company,
        source_type: @audience.source_type,
        filter_tree: @audience.filter_tree,
        exclude_filter_tree: @audience.exclude_filter_tree,
        manual_exclude_ids: @audience.try(:manual_exclude_ids),
        exclude_active_campaign_enrollees: @audience.try(:exclude_active_campaign_enrollees),
        exclude_active_nurture_enrollees: @audience.try(:exclude_active_nurture_enrollees)
      ).scope
      @campaign.sms_channel? ? scope_for_sms_compliance(scope) : scope
    rescue Audiences::FilterCompiler::CompilationError => e
      Rails.logger.error "[AudienceEnroller] filter compile failed: #{e.message}"
      @audience.source_type.constantize.none
    end

    # Mirror CampaignAudience#compute_matches SMS handling: only opted-in recipients
    # unless compliance is explicitly overridden; SMS to Accounts is unsupported.
    def scope_for_sms_compliance(scope)
      return scope if @audience.sms_compliance_override?
      return scope.none if @audience.source_type == 'Account'
      col = if scope.klass.column_names.include?('opt_in_sms') then :opt_in_sms
            elsif scope.klass.column_names.include?('sms_opt_in') then :sms_opt_in
            end
      col ? scope.where(col => true) : scope
    end

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
