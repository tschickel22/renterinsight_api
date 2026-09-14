# frozen_string_literal: true

module Plays
  # "Wake up cold leads": a short email sequence for leads that have gone quiet.
  #
  # One drip campaign with a live audience: leads with no activity for the
  # chosen number of days that have not become a deal, not already in another
  # campaign or follow-up sequence, and (by default) not getting the weekly
  # homes email. The campaign scheduler enrolls new matches as leads go quiet,
  # and each lead gets the sequence once.
  #
  # A reply or a click stops the rest of the emails (campaign goals) and, when
  # the dealer wants, gives the rep a task through a workflow scoped to this
  # campaign.
  class WakeUpColdLeads
    KEY = 'wake_up_cold_leads'
    NAME = 'Wake up cold leads'
    DESCRIPTION = 'Leads who go quiet get a short series of emails from their rep. ' \
                  'Anyone who replies or clicks stops getting them, and their rep gets a task to follow up.'

    WEEKLY_TAG = LeadResponsePlay::WEEKLY_HOMES_TAG
    IDLE_DAYS = [30, 60, 90, 180].freeze
    MAX_EMAILS = 5
    MAX_DAY = 120
    SENDERS = %w[owner company user].freeze
    FIELDS = {
      'first_name' => '{{first_name}}',
      'last_name' => '{{last_name}}',
      'rep_name' => '{{rep_name}}',
      'rep_phone' => '{{rep_phone}}',
      'dealership' => :dealership
    }.freeze
    SAMPLE_VALUES = { 'first_name' => 'Tia', 'last_name' => 'May', 'rep_name' => 'Rita Rep', 'rep_phone' => '(303) 555-0142' }.freeze
    FIELD_PATTERN = LeadResponsePlay::FIELD_PATTERN
    REPLY_TASK_HOURS = 4
    CLICK_TASK_HOURS = 24

    STAGES = {
      'in_sequence' => 'Getting wake-up emails',
      'woke_up' => 'Woke up',
      'no_response' => 'No response',
      'became_deal' => 'Became a deal',
      'unsubscribed' => 'Unsubscribed',
      'not_reachable' => 'Email not reachable'
    }.freeze
    PERIODS = Plays::Tracking::PERIODS

    class << self
      def kind
        'reengagement'
      end

      def hidden?
        false
      end

      def default_content
        {
          'idle_days' => 60,
          'sender' => 'owner',
          'sender_user_id' => nil,
          'skip_weekly' => true,
          'emails' => [
            { 'day' => 0, 'subject' => 'Still looking, {{first_name}}?', 'include_homes' => true,
              'body' => "Hi {{first_name}},\n\nIt has been a little while, so here are homes that are fresh on our lot. " \
                        "If one catches your eye, reply and I will set up a time to see it.\n\n{{rep_name}}" },
            { 'day' => 7, 'subject' => 'A few homes worth a second look', 'include_homes' => true,
              'body' => "Hi {{first_name}},\n\nHere are a few more homes on our lot that could be a good fit. " \
                        "Happy to answer any questions.\n\n{{rep_name}}" },
            { 'day' => 14, 'subject' => 'Should we close your file?', 'include_homes' => false,
              'body' => "Hi {{first_name}},\n\nIf you are still looking, just reply and I will get back in touch. " \
                        "If now is not the time, no worries, and I will close out your file.\n\n{{rep_name}}" }
          ],
          'reply_task' => true,
          'click_task' => true
        }
      end

      def normalize_content(raw)
        defaults = default_content
        given = (raw || {}).to_h.deep_stringify_keys
        merged = defaults.merge(given.slice(*defaults.keys))
        emails = merged['emails'].is_a?(Hash) ? merged['emails'].values : Array(merged['emails'])
        {
          'idle_days' => IDLE_DAYS.include?(merged['idle_days'].to_i) ? merged['idle_days'].to_i : defaults['idle_days'],
          'sender' => SENDERS.include?(merged['sender'].to_s) ? merged['sender'].to_s : defaults['sender'],
          'sender_user_id' => merged['sender_user_id'].presence&.to_i,
          'skip_weekly' => cast_bool(merged['skip_weekly']),
          'emails' => emails.select { |e| e.is_a?(Hash) }.first(MAX_EMAILS).map do |email|
            { 'day' => email['day'].to_i, 'subject' => email['subject'].to_s.strip, 'body' => email['body'].to_s.strip,
              'include_homes' => cast_bool(email['include_homes']) }
          end,
          'reply_task' => cast_bool(merged['reply_task']),
          'click_task' => cast_bool(merged['click_task'])
        }
      end

      def validate_content!(content, company)
        emails = content['emails']
        raise InstallError, 'Add at least one wake-up email.' if emails.empty?

        previous = -1
        emails.each_with_index do |email, index|
          label = "wake-up email #{index + 1}"
          raise InstallError, "Give #{label} a subject and a message." if email['subject'].blank? || email['body'].blank?
          raise InstallError, "Send #{label} between day 0 and day #{MAX_DAY}." unless (0..MAX_DAY).cover?(email['day'])
          raise InstallError, "Send #{label} at least a day after the one before it." if index.positive? && email['day'] <= previous

          previous = email['day']
          %w[subject body].each do |part|
            unknown = email[part].scan(FIELD_PATTERN).flatten.uniq - FIELDS.keys
            next if unknown.empty?

            raise InstallError, "#{unknown.map { |f| "{{#{f}}}" }.join(', ')} can't be used in #{label}. " \
                                "Available: #{FIELDS.keys.map { |f| "{{#{f}}}" }.join(', ')}."
          end
        end

        options = WeeklyHomesEmail.sender_options(company)
        case content['sender']
        when 'company'
          raise InstallError, 'Connect a dealership email account before sending from the dealership.' unless options[:company_mailbox]
        when 'user'
          raise InstallError, 'Choose someone with a connected email account to send from.' unless options[:users].any? { |u| u[:id] == content['sender_user_id'] }
        end
      end

      def definition(company)
        content = normalize_content(nil)
        {
          key: KEY,
          name: NAME,
          description: DESCRIPTION,
          kind: kind,
          hidden: false,
          fields: FIELDS.keys,
          idle_days_options: IDLE_DAYS,
          max_emails: MAX_EMAILS,
          sender_options: WeeklyHomesEmail.sender_options(company),
          default_content: content,
          map: map_for(company: company, content: content)
        }
      end

      def answers_for(installation)
        { 'sources' => [], 'content' => normalize_content((installation.answers || {})['content']) }
      end

      def campaign_for(installation)
        Campaign.find_by(company_id: installation.company_id, id: installation.asset_ids(:campaign_ids).first)
      end

      def installation_json(installation)
        company = installation.company
        content = answers_for(installation)['content']
        campaign = campaign_for(installation)
        {
          id: installation.id,
          status: installation.status,
          installed_at: installation.installed_at&.iso8601,
          updated_at: installation.updated_at&.iso8601,
          content: content,
          map: map_for(company: company, content: content),
          campaign: campaign && { id: campaign.id, name: campaign.name, status: campaign.status },
          workflow_rules: WorkflowRule.where(company_id: company.id, id: installation.asset_ids(:workflow_rule_ids))
                                      .where.not(status: 'archived')
                                      .map { |rule| { id: rule.id, name: rule.name, status: rule.status } }
        }
      end

      # No more wake-up emails go out and no new tasks are made. Tasks already
      # given stay.
      def uninstall!(installation)
        ActiveRecord::Base.transaction do
          campaign_for(installation)&.update!(status: 'archived')
          WorkflowRule.where(company_id: installation.company_id, id: installation.asset_ids(:workflow_rule_ids)).find_each do |rule|
            archive_rule!(rule)
          end
          installation.update!(status: 'uninstalled', uninstalled_at: Time.current)
        end
        installation
      end

      def archive_rule!(rule)
        rule.update!(status: 'archived') unless rule.status == 'archived'
        WorkflowRun.where(workflow_rule_id: rule.id, status: %w[pending running waiting]).find_each do |run|
          WorkflowEngine.cancel(run, reason: 'play_turned_off')
        end
      end

      def map_for(company:, content:)
        audience = "Leads that have not become a deal, are not already in another campaign or follow-up emails"
        audience += ', and are not getting the weekly homes email' if content['skip_weekly']
        steps = [
          { key: 'trigger', kind: 'trigger', title: "A lead has no activity for #{content['idle_days']} days",
            detail: "#{audience}. Each lead gets this once." }
        ]
        content['emails'].each_with_index do |email, index|
          preview = sample(company, email['body'])
          preview += "\n\n[Homes on your lot]" if email['include_homes']
          steps << { key: "email_#{index + 1}", kind: 'email', title: "Wake-up email #{index + 1}",
                     timing: email['day'].zero? ? 'Right away' : "Day #{email['day']}",
                     condition: index.zero? ? sender_phrase(company, content) : nil,
                     subject: sample(company, email['subject']), preview: preview }.compact
        end

        tasks = []
        tasks << "within #{REPLY_TASK_HOURS} hours when they reply" if content['reply_task']
        tasks << 'the next day when they click' if content['click_task']
        steps << { key: 'woke_up', kind: tasks.any? ? 'task' : 'end', title: 'They reply or click',
                   detail: ['The rest of the emails stop.', tasks.any? ? "Their rep gets a task #{tasks.join(', or ')}." : nil].compact.join(' ') }
        steps << { key: 'no_response', kind: 'end', title: 'No response', detail: 'They stay in your lead list and are not emailed by this play again.' }
        steps
      end

      # ── Results ──────────────────────────────────────────────────────────

      def performance_for(installation, period:, location_ids:)
        period = PERIODS.key?(period.to_s) ? period.to_s : Plays::Tracking::DEFAULT_PERIOD
        rows = recipient_rows(installation, location_ids, since: PERIODS[period]&.days&.ago)
        sends = CampaignSend.real.where(campaign_enrollment_id: rows.map { |r| r[:enrollment].id }).where.not(sent_at: nil)
        sent = sends.count
        task_runs = WorkflowRun.where(company_id: installation.company_id, workflow_rule_id: installation.asset_ids(:workflow_rule_ids),
                                      entity_type: 'Lead', entity_id: rows.map { |r| r[:lead].id })

        {
          period: period,
          stages: STAGES.map { |key, label| { key: key, label: label } },
          stage_counts: STAGES.keys.to_h { |stage| [stage, rows.count { |r| r[:stage] == stage }] },
          step_counts: rows.select { |r| r[:stage] == 'in_sequence' }
                           .each_with_object(Hash.new(0)) { |r, acc| acc["email_#{r[:enrollment].current_step_index.to_i + 1}"] += 1 },
          metrics: {
            leads_reached: rows.size,
            emails_sent: sent,
            open_rate: sent.zero? ? nil : (sends.where.not(opened_at: nil).count.to_f / sent).round(3),
            click_rate: sent.zero? ? nil : (sends.where.not(clicked_at: nil).count.to_f / sent).round(3),
            woke_up: rows.count { |r| r[:woke_up] },
            woke_up_rate: rows.empty? ? nil : (rows.count { |r| r[:woke_up] }.to_f / rows.size).round(3),
            deals: rows.count { |r| r[:stage] == 'became_deal' },
            unsubscribed: rows.count { |r| r[:stage] == 'unsubscribed' },
            rep_tasks: task_runs.count
          }
        }
      end

      def leads_for(installation, period:, location_ids:, stage:, page:, per_page:)
        period = PERIODS.key?(period.to_s) ? period.to_s : Plays::Tracking::DEFAULT_PERIOD
        rows = recipient_rows(installation, location_ids, since: PERIODS[period]&.days&.ago)
        rows = rows.select { |r| r[:stage] == stage.to_s } if STAGES.key?(stage.to_s)
        per_page = per_page.to_i.clamp(1, 100)
        page = [page.to_i, 1].max
        total = rows.size

        {
          items: (rows.slice((page - 1) * per_page, per_page) || []).map { |row| row_json(row) },
          meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil }
        }
      end

      def lead_journey_for(installation, lead, location_ids:)
        row = recipient_rows(installation, location_ids, lead_id: lead.id).first
        return nil unless row

        enrollment = row[:enrollment]
        events = [{ at: enrollment.created_at.iso8601, kind: 'trigger', title: 'Went quiet and started the wake-up emails', detail: nil }]
        steps = enrollment.campaign.campaign_steps.index_by(&:id)
        enrollment.campaign_sends.where.not(sent_at: nil).order(:sent_at).each do |send|
          number = steps[send.campaign_step_id]&.position.to_i + 1
          events << { at: send.sent_at.iso8601, kind: 'email', title: "Wake-up email #{number} sent", detail: steps[send.campaign_step_id]&.subject }
          events << { at: send.opened_at.iso8601, kind: 'opened', title: 'Opened it', detail: nil } if send.opened_at
          events << { at: send.clicked_at.iso8601, kind: 'clicked', title: 'Clicked a link', detail: nil } if send.clicked_at
          events << { at: send.replied_at.iso8601, kind: 'reply', title: 'Replied', detail: nil } if send.replied_at
          events << { at: send.bounced_at.iso8601, kind: 'stopped', title: 'The email bounced', detail: send.bounce_type } if send.bounced_at
        end
        if enrollment.unsubscribed_at
          events << { at: enrollment.unsubscribed_at.iso8601, kind: 'stopped', title: 'Unsubscribed', detail: nil }
        end

        runs = WorkflowRun.where(company_id: installation.company_id, workflow_rule_id: installation.asset_ids(:workflow_rule_ids),
                                 entity_type: 'Lead', entity_id: lead.id)
        activity_ids = WorkflowRunStep.where(workflow_run_id: runs.select(:id), step_type: 'create_activity', status: 'success')
                                      .pluck(:output).filter_map { |output| output&.dig('id') }
        LeadActivity.where(id: activity_ids).order(:created_at).each do |activity|
          events << { at: activity.created_at.iso8601, kind: 'task', title: "Task for the rep: #{activity.subject}", detail: nil }
          if activity.respond_to?(:completed_at) && activity.completed_at
            events << { at: activity.completed_at.iso8601, kind: 'task_done', title: 'Task completed', detail: nil }
          end
        end
        if row[:stage] == 'became_deal'
          events << { at: lead.converted_at&.iso8601, kind: 'deal', title: 'Became a deal', detail: nil }
        end

        ordered = events.each_with_index.sort_by { |event, index| [event[:at].to_s, index] }.map(&:first)
        { lead: row_json(row).merge(phone: lead.phone), events: ordered }
      end

      private

      def cast_bool(value)
        ActiveModel::Type::Boolean.new.cast(value) || false
      end

      def sample(company, text)
        text.to_s.gsub(FIELD_PATTERN) do
          field = Regexp.last_match(1)
          field == 'dealership' ? company.name : SAMPLE_VALUES.fetch(field, Regexp.last_match(0))
        end
      end

      def sender_phrase(company, content)
        case content['sender']
        when 'company' then 'From your dealership mailbox'
        when 'user'
          user = User.find_by(company_id: company.id, id: content['sender_user_id'])
          user ? "From #{LeadResponsePlay.display_name(user)}" : 'From the person you choose'
        else
          "From each lead's own rep. A lead with no rep, or whose rep has no connected mailbox, is skipped."
        end
      end

      def recipient_rows(installation, location_ids, since: nil, lead_id: nil)
        campaign = campaign_for(installation)
        return [] unless campaign

        enrollments = campaign.campaign_enrollments.real.where(recipient_type: 'Lead')
        enrollments = enrollments.where('campaign_enrollments.created_at >= ?', since) if since
        enrollments = enrollments.where(recipient_id: lead_id) if lead_id
        enrollments = enrollments.order(created_at: :desc).to_a
        leads = Lead.where(company_id: installation.company_id, id: enrollments.map(&:recipient_id))
        leads = leads.where(location_id: location_ids) if location_ids
        leads = leads.includes(:source, :owner).index_by(&:id)
        engaged = CampaignSend.where(campaign_enrollment_id: enrollments.map(&:id))
                              .where('clicked_at IS NOT NULL OR replied_at IS NOT NULL')
                              .distinct.pluck(:campaign_enrollment_id)
        last_sends = CampaignSend.where(campaign_enrollment_id: enrollments.map(&:id)).where.not(sent_at: nil)
                                 .order(:sent_at).to_a.group_by(&:campaign_enrollment_id).transform_values(&:last)

        enrollments.filter_map do |enrollment|
          lead = leads[enrollment.recipient_id]
          next unless lead

          woke_up = engaged.include?(enrollment.id) || enrollment.goal_met_at.present?
          stage = if lead.is_converted && (lead.converted_at.nil? || lead.converted_at >= enrollment.created_at) then 'became_deal'
                  elsif woke_up then 'woke_up'
                  elsif enrollment.status == 'unsubscribed' then 'unsubscribed'
                  elsif %w[bounced complained failed].include?(enrollment.status) then 'not_reachable'
                  elsif %w[pending active paused].include?(enrollment.status) then 'in_sequence'
                  else 'no_response'
                  end
          { enrollment: enrollment, lead: lead, stage: stage, woke_up: woke_up, last_send: last_sends[enrollment.id] }
        end
      end

      def row_json(row)
        lead = row[:lead]
        enrollment = row[:enrollment]
        detail, detail_at = case row[:stage]
                            when 'in_sequence'
                              enrollment.next_send_at ? ["Wake-up email #{enrollment.current_step_index.to_i + 1} goes out", enrollment.next_send_at] : ['Waiting to send', nil]
                            when 'woke_up' then ["Responded#{enrollment.goal_met_reason.present? ? " (#{enrollment.goal_met_reason})" : ''}", enrollment.goal_met_at || row[:last_send]&.sent_at]
                            when 'became_deal' then ['Converted to a deal', lead.converted_at]
                            when 'unsubscribed' then ['Unsubscribed', enrollment.unsubscribed_at]
                            when 'not_reachable' then ['The email could not be delivered', enrollment.bounced_at || enrollment.updated_at]
                            else ['All wake-up emails sent, no response', row[:last_send]&.sent_at]
                            end
        {
          lead_id: lead.id,
          name: [lead.first_name, lead.last_name].compact.join(' ').strip.presence || lead.email || "Lead ##{lead.id}",
          email: lead.email,
          source: lead.source&.name,
          rep: lead.owner && LeadResponsePlay.display_name(lead.owner),
          started_at: enrollment.created_at&.iso8601,
          stage: row[:stage],
          stage_label: STAGES.fetch(row[:stage]),
          detail: detail,
          detail_at: detail_at&.iso8601
        }
      end
    end

    # ── Install and customize ────────────────────────────────────────────

    def initialize(company:, user:, answers:, installation: nil)
      @company = company
      @user = user
      @answers = (answers || {}).to_h.deep_stringify_keys
      @installation = installation
    end

    def install!
      if PlayInstallation.active.exists?(company_id: @company.id, play_key: KEY)
        raise InstallError, "#{NAME} is already on. Customize it instead."
      end
      self.class.validate_content!(content, @company)

      campaign = nil
      installation = ActiveRecord::Base.transaction do
        campaign = @company.campaigns.create!(
          name: unique_campaign_name,
          description: "Created by the #{NAME} play.",
          status: 'draft',
          channel: 'email',
          campaign_type: 'drip',
          audience_mode: 'dynamic',
          send_window: {},
          utm_source: 'campaign',
          utm_medium: 'email',
          utm_campaign: KEY,
          created_by_user_id: @user.id,
          **campaign_settings
        )
        sync_steps(campaign)
        campaign.create_campaign_audience!(source_type: 'Lead', **audience_settings)
        unless campaign.can_start?
          raise InstallError, 'The wake-up emails could not start. Check that the sender has a connected email account.'
        end

        campaign.update!(status: 'running', started_at: Time.current)
        rules = sync_rules(campaign, {})

        PlayInstallation.create!(
          company_id: @company.id,
          play_key: KEY,
          status: 'active',
          answers: { content: content },
          assets: { campaign_ids: [campaign.id] }.merge(rule_assets(rules, {})),
          installed_by_user_id: @user&.id,
          installed_at: Time.current
        )
      end
      CampaignAudienceEnrollerJob.perform_later(campaign.id) if defined?(CampaignAudienceEnrollerJob)
      installation
    end

    # Updates the campaign and its rules in place. A lead partway through
    # keeps its place; later emails use the new words.
    def customize!
      raise InstallError, "#{NAME} is not on." unless @installation&.status == 'active'
      self.class.validate_content!(content, @company)

      campaign = self.class.campaign_for(@installation)
      raise InstallError, 'The campaign for this play is missing. Turn the play off and on again.' unless campaign

      ActiveRecord::Base.transaction do
        campaign.update!(**campaign_settings)
        sync_steps(campaign)
        campaign.campaign_audience.update!(**audience_settings)
        assets = (@installation.assets || {}).deep_stringify_keys
        rules = sync_rules(campaign, assets['rules'] || {})
        @installation.update!(answers: { content: content }, assets: assets.merge(rule_assets(rules, assets)))
      end
      CampaignAudienceEnrollerJob.perform_later(campaign.id) if defined?(CampaignAudienceEnrollerJob) && campaign.status == 'running'
      @installation
    end

    private

    def content
      @content ||= self.class.normalize_content(@answers['content'])
    end

    def campaign_settings
      identity = case content['sender']
                 when 'company' then { from_identity_type: 'Company', from_identity_id: @company.id }
                 when 'user' then { from_identity_type: 'User', from_identity_id: content['sender_user_id'] }
                 else { from_identity_type: 'Owner', from_identity_id: nil }
                 end
      # A reply or a click stops the rest of the sequence.
      identity.merge(goal_config: { 'primary_goal' => 'replied', 'additional_goals' => ['clicked'],
                                    'goal_actions' => { 'replied' => 'stop', 'clicked' => 'stop' } })
    end

    def audience_settings
      filter = {
        'type' => 'and',
        'children' => [
          { 'field' => 'last_activity_at', 'operator' => 'days_since_greater_than', 'value' => content['idle_days'] },
          { 'field' => 'is_converted', 'operator' => 'equals', 'value' => false }
        ]
      }
      # The column is NOT NULL; an empty tree excludes nobody.
      exclude = if content['skip_weekly']
                  Campaigns::AudienceTags.new(company: @company).prepare!(
                    { 'type' => 'and', 'children' => [{ 'field' => 'tags', 'operator' => 'tags_include', 'value' => WEEKLY_TAG }] }
                  )
                else
                  {}
                end
      { filter_tree: filter, exclude_filter_tree: exclude,
        exclude_active_campaign_enrollees: true, exclude_active_nurture_enrollees: true }
    end

    # Steps are matched by position. Extra steps are switched off rather than
    # deleted, so sends already made keep their step.
    def sync_steps(campaign)
      existing = campaign.campaign_steps.order(:position).to_a
      previous_day = 0
      content['emails'].each_with_index do |email, index|
        step = existing[index] || campaign.campaign_steps.new(position: index)
        step.update!(
          position: index,
          channel: 'email',
          wait_days: email['day'] - previous_day,
          wait_hours: 0,
          subject: fill(email['subject']),
          preheader: nil,
          is_active: true,
          body_blocks: blocks_for(email),
          inventory_block_config: email['include_homes'] ? { 'mode' => 'category_based', 'max_units' => 3, 'sort' => 'newest', 'fallback' => 'skip_block' } : nil
        )
        previous_day = email['day']
      end
      existing.drop(content['emails'].size).each { |step| step.update!(is_active: false) }
    end

    def blocks_for(email)
      html = ERB::Util.html_escape(email['body']).split(/\n{2,}/).map { |p| "<p>#{p.strip.gsub("\n", '<br>')}</p>" }.join
      html = html.gsub(FIELD_PATTERN) do
        target = FIELDS.fetch(Regexp.last_match(1))
        target == :dealership ? ERB::Util.html_escape(@company.name) : target
      end
      blocks = [{ 'type' => 'text', 'html' => html }]
      blocks << { 'type' => 'inventory', 'ref' => 'step.inventory_block_config' } if email['include_homes']
      blocks << { 'type' => 'footer_unsubscribe' }
      blocks
    end

    def fill(text)
      text.to_s.gsub(FIELD_PATTERN) do
        target = FIELDS.fetch(Regexp.last_match(1))
        target == :dealership ? @company.name : target
      end
    end

    # { 'replied' => rule|nil, 'clicked' => rule|nil }
    def sync_rules(campaign, current)
      {
        'replied' => sync_rule(current['replied'], content['reply_task'], "#{NAME}: replied", 'campaign.replied', campaign,
                               'Reply to {{entity.full_name}}: they answered a wake-up email', REPLY_TASK_HOURS),
        'clicked' => sync_rule(current['clicked'], content['click_task'], "#{NAME}: clicked", 'campaign.clicked', campaign,
                               'Call {{entity.full_name}}: they clicked a wake-up email', CLICK_TASK_HOURS)
      }
    end

    def sync_rule(existing_id, wanted, name, event_type, campaign, subject, due_hours)
      rule = existing_id && WorkflowRule.find_by(company_id: @company.id, id: existing_id)
      unless wanted
        self.class.archive_rule!(rule) if rule
        return nil
      end
      return rule if rule && rule.status != 'archived'

      steps = {
        'nodes' => [{ 'id' => 'rep_task', 'type' => 'create_activity', 'config' => {
          'activity_type' => 'task', 'subject' => subject,
          'description' => "Created by the #{NAME} play. This lead had gone quiet and just responded. " \
                           'Phone: {{entity.phone}}. Email: {{entity.email}}.',
          'priority' => 'high', 'assigned_to' => 'owner', 'due_in_hours' => due_hours
        } }],
        'edges' => []
      }
      created = @company.workflow_rules.create!(
        name: unique_rule_name(name),
        description: "Created by the #{NAME} play.",
        entity_type: 'Lead',
        status: 'draft',
        trigger: { 'event_type' => event_type, 'entity_type_filter' => 'Lead' },
        conditions: [{ 'field' => 'trigger.campaign_id', 'operator' => 'equals', 'value' => campaign.id }],
        steps: steps,
        parameters: {},
        halt_on_reply: 'false',
        created_by_user_id: @user&.id
      )
      validation = WorkflowRuleValidator.new(created).validate
      raise InstallError, "The play could not switch on #{created.name}: #{validation.errors.first}" unless validation.valid?

      created.update!(status: 'active')
      created
    end

    def rule_assets(rules, previous)
      ids = (Array(previous['workflow_rule_ids']).map(&:to_i) + rules.values.compact.map(&:id)).uniq
      { 'rules' => rules.transform_values { |rule| rule&.id }, 'workflow_rule_ids' => ids }
    end

    def unique_campaign_name
      scope = @company.campaigns.where.not(status: 'archived')
      return NAME unless scope.exists?(name: NAME)

      (2..100).each do |n|
        candidate = "#{NAME} (#{n})"
        return candidate unless scope.exists?(name: candidate)
      end
      "#{NAME} #{SecureRandom.hex(2)}"
    end

    def unique_rule_name(base)
      scope = @company.workflow_rules.where.not(status: 'archived')
      return base unless scope.exists?(name: base)

      (2..100).each do |n|
        candidate = "#{base} (#{n})"
        return candidate unless scope.exists?(name: candidate)
      end
      "#{base} #{SecureRandom.hex(2)}"
    end
  end
end
