# frozen_string_literal: true

module Automations
  # Everything that can message one lead or contact, and Stop for each
  # (Proactive Outreach E105 follow-up). Nurtures, starter plays, campaigns,
  # workflows, Quinn conversations and proactive outreach.
  #
  # Stopping never unsubscribes, suppresses or opts anyone out: the person can
  # be added to something later. Each stop leaves a note naming who and what.
  # A starter play is one row: its own workflows, nurtures and campaigns are
  # folded into it and stop together.
  class ForRecord
    Item = Struct.new(:kind, :id, :name, :kind_label, :status, :status_label, :detail, :last_at, :next_at, :link, :can_stop,
                      :stop_effect, keyword_init: true)

    class NotFound < StandardError; end

    STAFF_REASON = 'stopped_by_staff'
    CAMPAIGN_LIVE = %w[pending active].freeze
    NURTURE_LIVE = %w[idle running paused].freeze
    WORKFLOW_LIVE = %w[pending running waiting paused].freeze
    OUTREACH_LIVE = %w[selected drafted approved sending sent replied].freeze

    def initialize(company:, record:, user: nil)
      @company = company
      @record = record
      @user = user
    end

    def items
      plays = play_rows
      claimed = plays.flat_map { |row| row[:parts] }
      list = plays.map { |row| row[:item] }
      list += nurtures.reject { |e| claimed.include?([:nurture, e.id]) }.map { |e| nurture_item(e) }
      list += campaigns.reject { |e| claimed.include?([:campaign, e.id]) }.map { |e| campaign_item(e) }
      list += workflows.reject { |r| claimed.include?([:workflow, r.id]) }.map { |r| workflow_item(r) }
      list += conversations.map { |c| conversation_item(c) }
      list += outreach_targets.map { |t| outreach_item(t) }
      list
    end

    def payload
      list = items
      { items: list.map(&:to_h), active_count: list.count(&:can_stop) }
    end

    def stop!(kind, id)
      item = items.find { |i| i.kind == kind.to_s && i.id == id.to_i && i.can_stop }
      raise NotFound, 'That is no longer running for this person.' unless item

      stop_item(item)
      note!("Stopped #{item.kind_label.downcase} \"#{item.name}\"")
      item
    end

    def stop_all!
      stopped = items.select(&:can_stop)
      stopped.each { |item| stop_item(item) }
      note!("Stopped everything messaging this person: #{stopped.map { |i| "#{i.kind_label.downcase} \"#{i.name}\"" }.join(', ')}") if stopped.any?
      stopped.size
    end

    private

    def lead? = @record.is_a?(Lead)
    def type = @record.class.name

    # ---- what is running --------------------------------------------------

    def nurtures
      @nurtures ||= begin
        scope = NurtureEnrollment.where(enrollable_type: type, enrollable_id: @record.id)
        scope = scope.or(NurtureEnrollment.where(lead_id: @record.id)) if lead?
        scope.where(status: NURTURE_LIVE).includes(:nurture_sequence).order(:created_at).to_a
      end
    end

    # A recurring digest marks each person completed between sends and starts
    # them again next cycle, so a completed enrollment in a live recurring
    # campaign is still running.
    def campaigns
      @campaigns ||= CampaignEnrollment.where(company_id: @company.id, recipient_type: type, recipient_id: @record.id, status: CAMPAIGN_LIVE + ['completed'])
                                       .includes(:campaign).order(:created_at).to_a
                                       .reject { |e| e.campaign.nil? || e.campaign.try(:is_deleted) }
                                       .select { |e| e.status.in?(CAMPAIGN_LIVE) || self.class.recurring_live?(e.campaign) }
    end

    def self.recurring_live?(campaign)
      campaign.recurring? && campaign.status.in?(%w[scheduled running])
    end

    def workflows
      @workflows ||= WorkflowRun.where(company_id: @company.id, entity_type: type, entity_id: @record.id, status: WORKFLOW_LIVE)
                                .order(:created_at).to_a
    end

    def conversations
      @conversations ||= Conversation.open_now.where(company_id: @company.id, conversable: @record).order(:created_at).to_a
    end

    def outreach_targets
      return [] unless lead?

      @outreach_targets ||= OutreachTarget.where(company_id: @company.id, lead_id: @record.id, status: OUTREACH_LIVE)
                                          .includes(:outreach_wave).to_a
    end

    def play_rows
      return [] unless lead?

      PlayInstallation.active.where(company_id: @company.id).filter_map do |installation|
        play = Plays::Registry.find(installation.play_key, company: @company)
        next unless play

        runs = workflows.select { |r| installation.asset_ids(:workflow_rule_ids).include?(r.workflow_rule_id) }
        seqs = nurtures.select { |e| installation.asset_ids(:nurture_sequence_ids).include?(e.nurture_sequence_id) }
        camps = campaigns.select { |e| installation.asset_ids(:campaign_ids).include?(e.campaign_id) }
        next if runs.empty? && seqs.empty? && camps.empty?

        parts = runs.map { |r| [:workflow, r.id] } + seqs.map { |e| [:nurture, e.id] } + camps.map { |e| [:campaign, e.id] }
        bits = [("#{runs.size} #{'workflow'.pluralize(runs.size)}" if runs.any?), ("follow-up emails" if seqs.any?),
                ("#{camps.size} #{'campaign'.pluralize(camps.size)}" if camps.any?)].compact
        next_at = (runs.map(&:wait_until) + camps.map { |e| campaign_next_at(e) }).compact.select { |t| t > Time.current }.min
        last_at = camps.map(&:last_sent_at).compact.max
        item = Item.new(kind: 'play', id: installation.id, name: play::NAME, kind_label: 'Starter play', status: 'active', status_label: 'Running',
                        detail: "Includes #{bits.to_sentence}. Started #{(runs + seqs + camps).map(&:created_at).min.strftime('%b %-d')}.",
                        last_at: last_at, next_at: next_at, link: "/marketing/plays/#{installation.play_key}", can_stop: true,
                        stop_effect: 'The play stops for this person only: its workflow, follow-up emails and campaigns. ' \
                                     'It keeps running for everyone else. If the start tag is added again, the play starts again.')
        { item: item, parts: parts, runs: runs, seqs: seqs, camps: camps }
      end
    end

    # ---- rows -------------------------------------------------------------

    def nurture_item(enrollment)
      sequence = enrollment.nurture_sequence
      steps = sequence ? sequence.steps.size : 0
      Item.new(kind: 'nurture', id: enrollment.id, name: sequence&.name || 'Nurture', kind_label: 'Nurture', status: enrollment.status,
               status_label: enrollment.status == 'paused' ? 'Paused' : 'Running',
               detail: ["Step #{enrollment.current_step_index.to_i + 1}#{" of #{steps}" if steps.positive?}",
                        "started #{enrollment.created_at.strftime('%b %-d')}"].join(', ') + '.',
               link: '/crm?tab=nurturing', can_stop: true,
               stop_effect: 'The nurture ends for this person. It is not paused, so it no longer counts as active.')
    end

    def campaign_item(enrollment)
      campaign = enrollment.campaign
      between = enrollment.status == 'completed'
      Item.new(kind: 'campaign', id: enrollment.id, name: campaign.name, kind_label: 'Campaign', status: enrollment.status,
               status_label: between ? 'Between sends' : (campaign.status == 'running' ? 'Active' : "Campaign #{campaign.status}"),
               detail: "Added #{enrollment.created_at.strftime('%b %-d')}.#{' Repeats each cycle.' if campaign.recurring?}",
               last_at: enrollment.last_sent_at,
               next_at: campaign_next_at(enrollment),
               link: "/campaigns/#{campaign.id}", can_stop: true,
               stop_effect: 'They are taken out of this campaign. They are not unsubscribed and can be added to another campaign.')
    end

    # Between cycles of a weekly digest the next send is the campaign's next run,
    # not the person's last (stale) send time.
    def campaign_next_at(enrollment)
      campaign = enrollment.campaign
      return campaign.next_recurrence_at if enrollment.status == 'completed'

      enrollment.next_send_at if campaign.status.in?(%w[running scheduled])
    end

    def workflow_item(run)
      rule = WorkflowRule.find_by(id: run.workflow_rule_id)
      Item.new(kind: 'workflow', id: run.id, name: rule&.name || 'Workflow', kind_label: 'Workflow', status: run.status,
               status_label: run.status == 'waiting' ? 'Waiting' : run.status.humanize,
               detail: "Started #{(run.started_at || run.created_at).strftime('%b %-d')}.#{" Waiting: #{run.wait_reason.to_s.humanize.downcase}." if run.status == 'waiting' && run.wait_reason.present?}",
               next_at: run.wait_until, link: '/workflow-automation', can_stop: true,
               stop_effect: 'This workflow stops for this person. It keeps running for everyone else.')
    end

    def conversation_item(conversation)
      answering = conversation.status == 'active' && conversation.assistant_enabled
      channel = { 'sms' => 'text', 'email' => 'email', 'web_chat' => 'website chat' }[conversation.channel.to_s] || conversation.channel.to_s
      Item.new(kind: 'conversation', id: conversation.id, name: "Quinn #{channel} conversation", kind_label: 'Quinn',
               status: conversation.status, status_label: answering ? 'Quinn answering' : 'With your team',
               detail: ("Handed off: #{conversation.handoff_reason.to_s.humanize.downcase}." if conversation.status == 'handed_off' && conversation.handoff_reason.present?),
               last_at: conversation.last_outbound_at, next_at: (conversation.next_follow_up_at if answering),
               link: '/inbox', can_stop: true,
               stop_effect: 'The conversation is closed, so Quinn stops answering and following up. It reopens if they write back.')
    end

    def outreach_item(target)
      wave = target.outreach_wave
      Item.new(kind: 'outreach', id: target.id, name: wave&.name || 'Proactive outreach', kind_label: 'Outreach', status: target.status,
               status_label: target.status.humanize, detail: ("Held back for comparison, nothing is sent." if target.test_group == 'holdout'),
               last_at: target.last_sent_at, next_at: target.next_touch_at, link: '/marketing/outreach',
               can_stop: target.test_group != 'holdout',
               stop_effect: 'No more outreach messages go to this person from this wave.')
    end

    # ---- stopping ---------------------------------------------------------

    def stop_item(item)
      case item.kind
      when 'nurture' then stop_nurture(NurtureEnrollment.find(item.id))
      when 'campaign' then stop_campaign(CampaignEnrollment.find(item.id))
      when 'workflow' then WorkflowEngine.cancel(WorkflowRun.find(item.id), reason: STAFF_REASON)
      when 'conversation' then Conversation.find(item.id).update!(status: 'closed', ended_at: Time.current, next_follow_up_at: nil)
      when 'outreach' then OutreachTarget.find(item.id).stop!('Stopped by staff')
      when 'play'
        row = play_rows.find { |r| r[:item].id == item.id }
        row[:runs].each { |run| WorkflowEngine.cancel(run, reason: STAFF_REASON) }
        row[:seqs].each { |enrollment| stop_nurture(enrollment) }
        row[:camps].each { |enrollment| stop_campaign(enrollment) }
      end
      reset!
    end

    # Finished rather than paused, so it no longer reads as active anywhere.
    def stop_nurture(enrollment)
      context = (enrollment.context || {}).merge('stopped_by' => who, 'stopped_at' => Time.current.iso8601).deep_stringify_keys
      enrollment.update!(status: 'completed', context: context)
    end

    # Paused, as the campaign screen's own remove does. Never unsubscribed:
    # that status fires workflows and suppression.
    def stop_campaign(enrollment)
      enrollment.update!(status: 'paused')
      begin
        CampaignEvent.create!(company_id: @company.id, campaign_id: enrollment.campaign_id, campaign_enrollment_id: enrollment.id,
                              event_type: 'unenrolled', occurred_at: Time.current, payload: { 'reason' => STAFF_REASON, 'user_id' => @user&.id })
      rescue StandardError => e
        Rails.logger.warn("[Automations::ForRecord] campaign event not recorded: #{e.class}: #{e.message}")
      end
    end

    def reset!
      @nurtures = @campaigns = @workflows = @conversations = @outreach_targets = nil
    end

    def who
      [@user&.first_name, @user&.last_name].compact_blank.join(' ').presence || @user&.email || 'staff'
    end

    def note!(text)
      Note.create!(content: "#{text}. By #{who} on #{Date.current.strftime('%b %-d, %Y')}. Nothing was unsubscribed.",
                   entity_type: type.downcase, entity_id: @record.id.to_s, user_id: @user&.id, created_by_name: who,
                   category: 'general', author_type: 'staff')
    end
  end
end
