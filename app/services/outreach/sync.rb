# frozen_string_literal: true

module Outreach
  # Brings a wave's results up to date from what actually happened (backlog E105):
  # delivery, opens, opt-outs, and demos, including ones a person booked.
  class Sync
    DONE = %w[completed].freeze
    OPT_OUT_STATUSES = %w[selected drafted approved sending sent replied booked].freeze

    def initialize(wave)
      @wave = wave
      @company = wave.company
      @eligibility = Eligibility.new(@company)
    end

    def run
      @wave.outreach_targets.includes(:lead).find_each do |target|
        sync_demo(target)
        next unless target.test_group == 'contact' && target.first_sent_at

        sync_messages(target)
        sync_opt_out(target)
        target.record!('converted') if target.lead.is_converted == true && !target.recorded?('converted')
      end
    end

    private

    # Held-back leads are counted too: that is the comparison.
    def sync_demo(target)
      return unless @wave.started_at

      demo = LeadActivity.where(lead_id: target.lead_id, activity_type: 'meeting').where('created_at >= ?', @wave.started_at)
                         .where.not(status: 'cancelled').order(:created_at).first
      return unless demo

      unless target.recorded?('booked')
        target.record!('booked', at: demo.created_at, metadata: { activity_id: demo.id })
        attrs = { booked_at: demo.created_at, activity_id: demo.id, next_touch_at: nil }
        attrs[:status] = 'booked' if OutreachTarget::WORKING.include?(target.status) || target.status == 'selected'
        target.update!(attrs)
      end
      if demo.status == 'completed' && !target.recorded?('held')
        target.record!('held', at: demo.end_time || Time.current, metadata: { activity_id: demo.id })
        target.update!(held_at: demo.end_time || Time.current, status: 'held')
      elsif demo.status == 'no_show' && !target.recorded?('no_show')
        target.record!('no_show', at: demo.start_time || Time.current, metadata: { activity_id: demo.id })
      end
    end

    def sync_messages(target)
      sent = target.outreach_events.where(event_type: 'sent').where.not(communication_id: nil)
      communications = Communication.where(id: sent.select(:communication_id)).index_by(&:id)
      communications.each_value do |message|
        channel = message.channel == 'email' ? 'email' : 'text'
        status = message.status.to_s
        target.record!('delivered', channel: channel, communication_id: message.id) if status.in?(%w[delivered opened clicked])
        target.record!('bounced', channel: channel, communication_id: message.id) if status == 'bounced'
        target.record!('undelivered', channel: channel, communication_id: message.id) if channel == 'text' && status.in?(%w[failed undelivered])
        sync_open(target, message) if channel == 'email'
      end
      complaint = target.lead.email.present? && CampaignSuppression.where(company_id: @company.id, reason: 'complaint', email_address: target.lead.email.downcase).exists?
      target.record!('complained') if complaint && !target.recorded?('complained')
    end

    # Mail scanners open everything on arrival; only people count.
    def sync_open(target, message)
      return if target.outreach_events.where(event_type: 'opened', communication_id: message.id).exists?

      open = CommunicationEvent.where(communication_id: message.id, event_type: 'opened').order(:occurred_at).detect do |event|
        !ScannerOpen.scanner?(user_agent: event.user_agent, sent_at: message.created_at, at: event.occurred_at)
      end
      target.record!('opened', channel: 'email', communication_id: message.id, at: open.occurred_at) if open
    end

    def sync_opt_out(target)
      return unless OPT_OUT_STATUSES.include?(target.status) && @eligibility.opted_out?(target.lead)

      target.record!('unsubscribed') unless target.recorded?('unsubscribed')
      target.stop!('opted out')
    end
  end
end
