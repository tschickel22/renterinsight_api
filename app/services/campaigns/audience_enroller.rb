module Campaigns
  class AudienceEnroller
    def initialize(campaign:)
      @campaign = campaign
      @audience = @campaign.campaign_audience
    end

    def enroll_all
      return 0 unless @audience

      first_step = @campaign.campaign_steps.active.ordered.first
      first_wait_seconds = ((first_step&.wait_days || 0) * 86400) + ((first_step&.wait_hours || 0) * 3600)
      earliest_send_at = Time.current + first_wait_seconds.seconds

      # Every enrollment used to get an IDENTICAL next_send_at, so enrolling 490
      # recipients made 490 sends due in the same instant and the scheduler
      # dispatched them as fast as the queue drained: 225 in one minute, which
      # got the mailbox blocked by Microsoft. Slots are now spread at the
      # mailbox's configured rate. One pacer per mailbox, since Owner-mode
      # campaigns enroll across many mailboxes and each has its own budget.
      pacers = Hash.new do |cache, key|
        cache[key] = Messaging::SendPacer.new(connection_key: key, earliest: earliest_send_at)
      end

      # Contact-value dedupe set — so an email that exists on BOTH a Lead
      # row and a Contact row for the same person only sends once for this
      # campaign. Seeded with existing enrollments' snapshot addresses so
      # a rerun (dynamic mode / recurrence cycle) doesn't double-count.
      seen_contact_values = Set.new(existing_snapshot_values)

      enrolled = 0
      each_source_type do |source_type, scope|
        scope.find_each do |record|
          contact_value = if @campaign.email_channel?
                            record.try(:email)&.downcase
                          else
                            normalize_phone(record.try(:phone))
                          end
          next if contact_value.blank?
          next if CampaignSuppression.suppressed?(@campaign.company_id, contact_value)
          next unless seen_contact_values.add?(contact_value)

          attrs = {
            company_id: @campaign.company_id, campaign_id: @campaign.id,
            recipient_type: source_type, recipient_id: record.id,
            status: 'pending', current_step_index: 0
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

          # Claimed only once the record is definitely being enrolled, so skipped
          # duplicates don't burn slots and leave dead air in the schedule.
          connection_key = connection_key_for(record)
          attrs[:sending_connection_key] = connection_key
          attrs[:next_send_at] = pacers[connection_key].next_slot

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
      end

      if @campaign.audience_mode == 'static' && @campaign.audience_snapshot_at.nil?
        @campaign.update_column(:audience_snapshot_at, Time.current)
      end

      # Keep the audience count meaningful for dynamic campaigns. The stored
      # estimated_count is a FilterCompiler estimate frozen at audience-edit
      # time, so tagging a lead in (which enrolls it here) never moved the
      # number — it sat at the launch value. For a dynamic campaign the true
      # audience IS the live enrolled set, which grows as new records match,
      # so mirror that count. (Recomputing the filter estimate instead would
      # shrink it, since the audience excludes active-campaign enrollees.)
      if @audience && @campaign.audience_mode == 'dynamic'
        live = @campaign.campaign_enrollments.active.count
        @audience.update_columns(estimated_count: live, estimated_at: Time.current)
      end

      enrolled
    end

    # Yields [source_type, scope] for the primary source type plus each
    # additional_source_types entry. Enables one campaign to enroll from
    # Lead + Contact simultaneously (weekly-newsletter case).
    def each_source_type
      types = [@audience.source_type] + Array(@audience.try(:additional_source_types))
      types.uniq.compact.each do |type|
        # Each type gets its own filter-compiled scope so the same
        # audience filter_tree applies (e.g. tagged 'weekly-favorites').
        yield type, audience_scope_for(type)
      end
    end

    def existing_snapshot_values
      col = @campaign.email_channel? ? :email_address_snapshot : :sms_phone_snapshot
      values = @campaign.campaign_enrollments.where.not(col => nil).pluck(col)
      @campaign.email_channel? ? values.map { |v| v.to_s.downcase } : values
    end

    private

    # Which mailbox this recipient's sends will go through, used to pick the
    # right pacer. Memoized hard: for every identity type except Owner the
    # answer is the same for the whole audience, and Owner mode repeats per
    # owner, so this stays at a handful of queries rather than one per record.
    def connection_key_for(record)
      if @campaign.from_identity_type == 'Owner'
        owner_id = record.try(:owner_id) || record.try(:owner)&.id
        @owner_connection_keys ||= {}
        return @owner_connection_keys[owner_id] if @owner_connection_keys.key?(owner_id)
        @owner_connection_keys[owner_id] = @campaign.sending_connection_key(recipient: record)
      else
        return @fixed_connection_key if defined?(@fixed_connection_key)
        @fixed_connection_key = @campaign.sending_connection_key
      end
    end

    # The exact audience set — the SAME Audiences::FilterCompiler the count/preview/members
    # use — so who gets enrolled matches what the audience screen shows. This applies the
    # filter AND every exclusion (exclude_filter_tree, manual_exclude_ids, active-campaign
    # and active-nurture excludes), which the old per-record ConditionEvaluator path skipped.
    # SMS opt-in compliance is layered on top for SMS campaigns.
    def audience_scope
      audience_scope_for(@audience.source_type)
    end

    # Applies the same filter tree / excludes to any given source type so
    # cross-source enrollment (Lead + Contact tagged 'weekly-favorites')
    # yields the same semantic audience across each type.
    def audience_scope_for(source_type)
      scope = Audiences::FilterCompiler.new(
        company: @campaign.company,
        source_type: source_type,
        filter_tree: @audience.filter_tree,
        exclude_filter_tree: @audience.exclude_filter_tree,
        manual_exclude_ids: @audience.try(:manual_exclude_ids),
        exclude_active_campaign_enrollees: @audience.try(:exclude_active_campaign_enrollees),
        exclude_active_nurture_enrollees: @audience.try(:exclude_active_nurture_enrollees)
      ).scope
      @campaign.sms_channel? ? scope_for_sms_compliance(scope) : scope
    rescue Audiences::FilterCompiler::CompilationError => e
      Rails.logger.error "[AudienceEnroller] filter compile failed for #{source_type}: #{e.message}"
      source_type.constantize.none
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
