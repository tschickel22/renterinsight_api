# frozen_string_literal: true

module Plays
  # "Weekly homes email": every week, each lead who wants updates gets an email
  # with homes on the lot, from their own rep by default.
  #
  # A different kind of play from the lead responses. It runs as one recurring
  # campaign rather than workflows: leads join by carrying the weekly homes tag
  # (New Facebook lead and Walk-in visit add it to every lead they handle) and
  # leave when they unsubscribe or become a deal.
  class WeeklyHomesEmail
    KEY = 'weekly_homes_email'
    NAME = 'Weekly homes email'
    DESCRIPTION = 'Every week, leads who want updates get an email with homes on your lot, sent from their rep. ' \
                  'Leads join when a play or a rep tags them, and leave when they unsubscribe or become a deal.'

    TAG = LeadResponsePlay::WEEKLY_HOMES_TAG
    DAYS = %w[monday tuesday wednesday thursday friday saturday sunday].freeze
    CRON_DAY = { 'sunday' => 0, 'monday' => 1, 'tuesday' => 2, 'wednesday' => 3, 'thursday' => 4, 'friday' => 5, 'saturday' => 6 }.freeze
    SENDERS = %w[owner company user].freeze
    SORTS = { 'newest' => 'Newest first', 'price_low' => 'Lowest price first', 'price_high' => 'Highest price first' }.freeze
    MAX_HOMES = [3, 6, 9].freeze
    FIELDS = { 'first_name' => '{{first_name}}', 'last_name' => '{{last_name}}', 'dealership' => :dealership }.freeze
    FIELD_PATTERN = LeadResponsePlay::FIELD_PATTERN

    STAGES = {
      'subscribed' => 'Getting the weekly email',
      'became_deal' => 'Became a deal',
      'unsubscribed' => 'Unsubscribed',
      'not_reachable' => 'Email not reachable'
    }.freeze
    PERIODS = Plays::Tracking::PERIODS

    class << self
      def kind
        'recurring_email'
      end

      def hidden?
        false
      end

      def default_content
        {
          'day' => 'tuesday',
          'time' => '09:00',
          'sender' => 'owner',
          'sender_user_id' => nil,
          'subject' => "{{first_name}}, this week's homes at {{dealership}}",
          'intro' => "Hi {{first_name}},\n\nHere are homes on our lot this week that could be a good fit. Reply to this " \
                     'email if one catches your eye and we will set up a time to see it.',
          'button_label' => 'See all our homes',
          'max_homes' => 6,
          'sort' => 'newest',
          'match_budget' => true,
          'require_photos' => true
        }
      end

      def normalize_content(raw)
        defaults = default_content
        given = (raw || {}).to_h.deep_stringify_keys
        merged = defaults.merge(given.slice(*defaults.keys))
        {
          'day' => DAYS.include?(merged['day'].to_s) ? merged['day'].to_s : defaults['day'],
          'time' => merged['time'].to_s.match?(/\A([01]?\d|2[0-3]):[0-5]\d\z/) ? merged['time'].to_s : defaults['time'],
          'sender' => SENDERS.include?(merged['sender'].to_s) ? merged['sender'].to_s : defaults['sender'],
          'sender_user_id' => merged['sender_user_id'].presence&.to_i,
          'subject' => merged['subject'].to_s.strip,
          'intro' => merged['intro'].to_s.strip,
          'button_label' => merged['button_label'].to_s.strip,
          'max_homes' => MAX_HOMES.include?(merged['max_homes'].to_i) ? merged['max_homes'].to_i : defaults['max_homes'],
          'sort' => SORTS.key?(merged['sort'].to_s) ? merged['sort'].to_s : defaults['sort'],
          'match_budget' => ActiveModel::Type::Boolean.new.cast(merged['match_budget']) || false,
          'require_photos' => ActiveModel::Type::Boolean.new.cast(merged['require_photos']) || false
        }
      end

      # Who can send, so the dialog only offers what will actually go out.
      def sender_options(company)
        user_ids = UserEmailConnection.where(company_id: company.id, is_active: true).pluck(:user_id).uniq
        {
          company_mailbox: CompanyEmailConnection.where(company_id: company.id, is_active: true).exists?,
          users: User.where(company_id: company.id, status: 'active', id: user_ids).map do |user|
            { id: user.id, name: LeadResponsePlay.display_name(user) }
          end
        }
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
          days: DAYS,
          sorts: SORTS.map { |key, label| { key: key, label: label } },
          max_homes_options: MAX_HOMES,
          sender_options: sender_options(company),
          time_zone: company.time_zone,
          default_content: content,
          map: map_for(company: company, content: content)
        }
      end

      # Other plays ask which lead sources a play claims; this one claims none.
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
          campaign: campaign && {
            id: campaign.id,
            name: campaign.name,
            status: campaign.status,
            next_send_at: next_send_at(campaign)&.iso8601
          },
          sources: [], reps_by_location: {}, send_texts: false,
          intake_forms: [], workflow_rules: [], nurture_sequences: [], rotations: []
        }
      end

      def uninstall!(installation)
        ActiveRecord::Base.transaction do
          campaign_for(installation)&.update!(status: 'archived')
          installation.update!(status: 'uninstalled', uninstalled_at: Time.current)
        end
        installation
      end

      def next_send_at(campaign)
        return campaign.scheduled_at if campaign.status == 'scheduled' && campaign.scheduled_at
        return nil unless %w[scheduled running].include?(campaign.status)

        campaign.next_recurrence_at
      end

      def map_for(company:, content:)
        sample = { 'first_name' => 'Tia', 'last_name' => 'May', 'dealership' => company.name }
        fill = ->(text) { text.to_s.gsub(FIELD_PATTERN) { sample.fetch(Regexp.last_match(1), Regexp.last_match(0)) } }
        homes = "Up to #{content['max_homes']} homes, #{SORTS.fetch(content['sort']).downcase}"
        homes += ', matched to the lead\'s budget when one is on file' if content['match_budget']
        homes += ', only homes with photos' if content['require_photos']

        [
          { key: 'trigger', kind: 'trigger', title: "Leads tagged #{TAG}",
            detail: 'New Facebook lead and Walk-in visit add this tag to every lead they handle. A rep can also add it by hand.' },
          { key: 'schedule', kind: 'wait', title: "Every #{content['day'].capitalize} at #{display_time(content['time'])}",
            detail: "In your dealership's time zone (#{company.time_zone})" },
          { key: 'weekly_email', kind: 'email', title: 'Weekly homes email', condition: sender_phrase(company, content),
            subject: fill.call(content['subject']),
            preview: [fill.call(content['intro']), "[#{homes}]", "[Button: #{content['button_label']}]"].join("\n\n"),
            detail: 'Includes an unsubscribe link.' },
          { key: 'leave', kind: 'end', title: 'Leaves the email when they unsubscribe or become a deal' }
        ]
      end

      # ── Results ──────────────────────────────────────────────────────────

      def performance_for(installation, period:, location_ids:)
        period = PERIODS.key?(period.to_s) ? period.to_s : Plays::Tracking::DEFAULT_PERIOD
        rows = recipient_rows(installation, location_ids)
        campaign = campaign_for(installation)
        sends = period_sends(campaign, rows.map { |r| r[:enrollment].id }, period)
        sent = sends.count
        opened = sends.where.not(opened_at: nil).count
        clicked_enrollments = sends.where.not(clicked_at: nil).distinct.count(:campaign_enrollment_id)

        {
          period: period,
          stages: STAGES.map { |key, label| { key: key, label: label } },
          stage_counts: STAGES.keys.to_h { |stage| [stage, rows.count { |r| r[:stage] == stage }] },
          step_counts: { 'weekly_email' => rows.count { |r| r[:stage] == 'subscribed' } },
          metrics: {
            recipients: rows.count { |r| r[:stage] == 'subscribed' },
            emails_sent: sent,
            open_rate: sent.zero? ? nil : (opened.to_f / sent).round(3),
            click_rate: sent.zero? ? nil : (sends.where.not(clicked_at: nil).count.to_f / sent).round(3),
            leads_clicked: clicked_enrollments,
            unsubscribed: rows.count { |r| r[:stage] == 'unsubscribed' },
            deals: rows.count { |r| r[:stage] == 'became_deal' },
            next_send_at: campaign && next_send_at(campaign)&.iso8601
          }
        }
      end

      def leads_for(installation, period:, location_ids:, stage:, page:, per_page:)
        rows = recipient_rows(installation, location_ids)
        rows = rows.select { |r| r[:stage] == stage.to_s } if STAGES.key?(stage.to_s)
        per_page = per_page.to_i.clamp(1, 100)
        page = [page.to_i, 1].max
        total = rows.size
        items = rows.sort_by { |r| r[:enrollment].created_at }.reverse.slice((page - 1) * per_page, per_page) || []

        {
          items: items.map { |row| recipient_json(row) },
          meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil }
        }
      end

      def lead_journey_for(installation, lead, location_ids:)
        row = recipient_rows(installation, location_ids, lead_id: lead.id).first
        return nil unless row

        enrollment = row[:enrollment]
        subject = campaign_for(installation)&.campaign_steps&.first&.subject
        events = [{ at: enrollment.created_at.iso8601, kind: 'trigger', title: 'Joined the weekly homes email', detail: nil }]
        enrollment.campaign_sends.where.not(sent_at: nil).order(:sent_at).each do |send|
          events << { at: send.sent_at.iso8601, kind: 'email', title: 'Weekly homes email sent', detail: subject }
          events << { at: send.opened_at.iso8601, kind: 'opened', title: 'Opened the email', detail: nil } if send.opened_at
          events << { at: send.clicked_at.iso8601, kind: 'clicked', title: 'Clicked a home or link', detail: nil } if send.clicked_at
          events << { at: send.bounced_at.iso8601, kind: 'stopped', title: 'The email bounced', detail: send.bounce_type } if send.bounced_at
        end
        if enrollment.try(:unsubscribed_at)
          events << { at: enrollment.unsubscribed_at.iso8601, kind: 'stopped', title: 'Unsubscribed', detail: nil }
        end
        if lead.is_converted && lead.converted_at
          events << { at: lead.converted_at.iso8601, kind: 'deal', title: 'Became a deal', detail: nil }
        end

        { lead: recipient_json(row).merge(phone: lead.phone), events: events.sort_by { |e| e[:at].to_s } }
      end

      private

      def recipient_rows(installation, location_ids, lead_id: nil)
        campaign = campaign_for(installation)
        return [] unless campaign

        enrollments = campaign.campaign_enrollments.real.where(recipient_type: 'Lead')
        enrollments = enrollments.where(recipient_id: lead_id) if lead_id
        enrollments = enrollments.to_a
        leads = Lead.where(company_id: installation.company_id, id: enrollments.map(&:recipient_id))
        leads = leads.where(location_id: location_ids) if location_ids
        leads = leads.includes(:source, :owner).index_by(&:id)
        last_sends = CampaignSend.where(campaign_enrollment_id: enrollments.map(&:id)).where.not(sent_at: nil)
                                 .order(:sent_at).to_a.group_by(&:campaign_enrollment_id).transform_values(&:last)

        enrollments.filter_map do |enrollment|
          lead = leads[enrollment.recipient_id]
          next unless lead

          stage = if lead.is_converted
                    'became_deal'
                  elsif enrollment.status == 'unsubscribed'
                    'unsubscribed'
                  elsif %w[bounced complained failed].include?(enrollment.status)
                    'not_reachable'
                  else
                    'subscribed'
                  end
          { enrollment: enrollment, lead: lead, stage: stage, last_send: last_sends[enrollment.id] }
        end
      end

      def recipient_json(row)
        lead = row[:lead]
        send = row[:last_send]
        detail, detail_at = if send
                              action = send.clicked_at ? 'clicked' : (send.opened_at ? 'opened' : 'not opened yet')
                              ["Last email #{action}, sent", send.sent_at]
                            else
                              ['Joined, first email goes out with the next send', row[:enrollment].created_at]
                            end
        {
          lead_id: lead.id,
          name: [lead.first_name, lead.last_name].compact.join(' ').strip.presence || lead.email || "Lead ##{lead.id}",
          email: lead.email,
          source: lead.source&.name,
          rep: lead.owner && LeadResponsePlay.display_name(lead.owner),
          started_at: row[:enrollment].created_at&.iso8601,
          stage: row[:stage],
          stage_label: STAGES.fetch(row[:stage]),
          detail: detail,
          detail_at: detail_at&.iso8601
        }
      end

      def period_sends(campaign, enrollment_ids, period)
        return CampaignSend.none unless campaign

        scope = CampaignSend.real.where(campaign_id: campaign.id, campaign_enrollment_id: enrollment_ids).where.not(sent_at: nil)
        scope = scope.where('sent_at >= ?', PERIODS[period].days.ago) if PERIODS[period]
        scope
      end

      def sender_phrase(company, content)
        case content['sender']
        when 'company' then 'From your dealership mailbox'
        when 'user'
          user = User.find_by(company_id: company.id, id: content['sender_user_id'])
          user ? "From #{LeadResponsePlay.display_name(user)}" : 'From the person you choose'
        else
          "From each lead's own rep. A lead with no rep, or whose rep has no connected mailbox, is skipped that week."
        end
      end

      def display_time(time)
        hour, minute = time.split(':').map(&:to_i)
        suffix = hour >= 12 ? 'PM' : 'AM'
        hour12 = (hour % 12).zero? ? 12 : hour % 12
        format('%<h>d:%<m>02d %<s>s', h: hour12, m: minute, s: suffix)
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
      validate!

      ActiveRecord::Base.transaction do
        tag = @company.tags.find_or_create_by!(name: TAG) do |t|
          t.color = '#0F766E'
          t.is_active = true
          t.is_system = false
        end

        campaign = @company.campaigns.create!(
          name: unique_campaign_name,
          description: "Created by the #{NAME} play.",
          status: 'draft',
          channel: 'email',
          campaign_type: 'recurring_digest',
          audience_mode: 'dynamic',
          goal_config: {},
          send_window: {},
          utm_source: 'campaign',
          utm_medium: 'email',
          utm_campaign: KEY,
          created_by_user_id: @user.id,
          **campaign_settings
        )
        campaign.campaign_steps.create!(position: 0, channel: 'email', wait_days: 0, wait_hours: 0, **step_settings)
        campaign.create_campaign_audience!(source_type: 'Lead', filter_tree: audience_filter)

        start!(campaign)

        PlayInstallation.create!(
          company_id: @company.id,
          play_key: KEY,
          status: 'active',
          answers: { content: content },
          assets: { campaign_ids: [campaign.id], tag_ids: [tag.id] },
          installed_by_user_id: @user&.id,
          installed_at: Time.current
        )
      end
    end

    # Updates the campaign in place. A cycle already sending finishes as it
    # started; the next one uses these settings.
    def customize!
      raise InstallError, "#{NAME} is not on." unless @installation&.status == 'active'
      validate!

      campaign = self.class.campaign_for(@installation)
      raise InstallError, 'The weekly email campaign for this play is missing. Turn the play off and on again.' unless campaign

      ActiveRecord::Base.transaction do
        campaign.update!(**campaign_settings)
        step = campaign.campaign_steps.order(:position).first || campaign.campaign_steps.new(position: 0, channel: 'email')
        step.update!(**step_settings)
        campaign.update!(scheduled_at: campaign.next_recurrence_at) if campaign.status == 'scheduled'
        @installation.update!(answers: { content: content })
      end
      @installation
    end

    private

    def content
      @content ||= self.class.normalize_content(@answers['content'])
    end

    def validate!
      raise InstallError, 'Give the weekly email a subject.' if content['subject'].blank?
      raise InstallError, 'Write a short introduction for the weekly email.' if content['intro'].blank?
      raise InstallError, 'Give the button a label.' if content['button_label'].blank?

      %w[subject intro button_label].each do |part|
        unknown = content[part].scan(FIELD_PATTERN).flatten.uniq - FIELDS.keys
        next if unknown.empty?

        raise InstallError, "#{unknown.map { |f| "{{#{f}}}" }.join(', ')} can't be used in the weekly email. " \
                            "Available: #{FIELDS.keys.map { |f| "{{#{f}}}" }.join(', ')}."
      end

      options = self.class.sender_options(@company)
      case content['sender']
      when 'company'
        raise InstallError, 'Connect a dealership email account before sending from the dealership.' unless options[:company_mailbox]
      when 'user'
        unless options[:users].any? { |u| u[:id] == content['sender_user_id'] }
          raise InstallError, 'Choose someone with a connected email account to send from.'
        end
      end
    end

    def campaign_settings
      hour, minute = content['time'].split(':').map(&:to_i)
      identity = case content['sender']
                 when 'company' then { from_identity_type: 'Company', from_identity_id: @company.id }
                 when 'user' then { from_identity_type: 'User', from_identity_id: content['sender_user_id'] }
                 else { from_identity_type: 'Owner', from_identity_id: nil }
                 end
      { recurrence_cron: "#{minute} #{hour} * * #{CRON_DAY.fetch(content['day'])}" }.merge(identity)
    end

    def step_settings
      {
        subject: fill_text(content['subject']),
        preheader: 'Homes on our lot this week',
        is_active: true,
        body_blocks: [
          { 'type' => 'text', 'html' => intro_html },
          { 'type' => 'inventory', 'ref' => 'step.inventory_block_config' },
          { 'type' => 'button', 'text' => content['button_label'], 'href' => '{{public_inventory_url}}' },
          { 'type' => 'footer_unsubscribe' }
        ],
        inventory_block_config: {
          'mode' => content['match_budget'] ? 'segment_based' : 'category_based',
          'max_units' => content['max_homes'],
          'sort' => content['sort'],
          'fallback' => 'show_cta',
          'segment_preferences' => { 'use_recipient_budget' => content['match_budget'] },
          'filters' => { 'require_images' => content['require_photos'] }
        }
      }
    end

    # Leads who asked for the email and have not become a deal.
    def audience_filter
      tree = {
        'type' => 'and',
        'children' => [
          { 'field' => 'tags', 'operator' => 'tags_include', 'value' => TAG },
          { 'field' => 'is_converted', 'operator' => 'equals', 'value' => false }
        ]
      }
      Campaigns::AudienceTags.new(company: @company).prepare!(tree)
    end

    # Scheduled for the next send; the scheduler opens each cycle from there.
    def start!(campaign)
      unless campaign.can_start?
        raise InstallError, 'The weekly email could not be scheduled. Check that the sender has a connected email account.'
      end

      campaign.update!(status: 'scheduled', scheduled_at: campaign.next_recurrence_at, started_at: Time.current)
    end

    def fill_text(text)
      text.to_s.gsub(FIELD_PATTERN) do
        target = FIELDS.fetch(Regexp.last_match(1))
        target == :dealership ? @company.name : target
      end
    end

    def intro_html
      escaped = ERB::Util.html_escape(content['intro']).split(/\n{2,}/).map { |p| "<p>#{p.strip.gsub("\n", '<br>')}</p>" }.join
      escaped.gsub(FIELD_PATTERN) do
        target = FIELDS.fetch(Regexp.last_match(1))
        target == :dealership ? ERB::Util.html_escape(@company.name) : target
      end
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
  end
end
