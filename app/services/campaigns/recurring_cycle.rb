# frozen_string_literal: true

module Campaigns
  # Opens the next cycle of a recurring campaign.
  #
  # A recurring digest used to reach each person once, ever. By the second
  # cycle every existing recipient had a completed enrollment, AudienceEnroller
  # skips anyone already enrolled, and CampaignSender refuses a step it has sent
  # before. "Weekly" meant "the week you joined": Evangeline's weekly homes
  # email ran for two months on a single send.
  #
  # This resets the recipients who still belong in the audience back to the
  # first step, paced like a fresh enrollment, and stamps cycle_started_at so
  # the duplicate guard only counts this cycle's sends.
  class RecurringCycle
    # Unsubscribed, bounced, failed, paused and goal-stopped recipients stay
    # where they are. Only people who simply finished last cycle go again.
    RESETTABLE_STATUSES = %w[completed].freeze

    def initialize(campaign:, now: Time.current)
      @campaign = campaign
      @now = now
    end

    # Returns how many enrollments were reset.
    def start!
      return 0 unless @campaign.recurring?

      @campaign.update_column(:cycle_started_at, @now)

      members = audience_member_keys
      pacers = Hash.new do |cache, key|
        cache[key] = Messaging::SendPacer.new(connection_key: key, earliest: @now)
      end

      reset = 0
      @campaign.campaign_enrollments.real.where(status: RESETTABLE_STATUSES).find_each do |enrollment|
        # Untagged, or no longer matching the filter: they are out of the digest.
        next unless members.include?([enrollment.recipient_type, enrollment.recipient_id])

        address = enrollment.email_address_snapshot.presence || enrollment.sms_phone_snapshot
        next if address.present? && CampaignSuppression.suppressed?(@campaign.company_id, address)

        enrollment.update!(
          status: 'pending',
          current_step_index: 0,
          next_send_at: pacers[enrollment.sending_connection_key].next_slot
        )
        reset += 1
      end
      reset
    end

    private

    # The same audience AudienceEnroller would enroll today, as
    # [recipient_type, id] pairs.
    def audience_member_keys
      keys = Set.new
      return keys unless @campaign.campaign_audience

      Campaigns::AudienceEnroller.new(campaign: @campaign).each_source_type do |source_type, scope|
        scope.pluck("#{scope.klass.table_name}.id").each { |id| keys << [source_type, id] }
      end
      keys
    end
  end
end
