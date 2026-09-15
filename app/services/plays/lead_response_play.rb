# frozen_string_literal: true

module Plays
  # A lead response play: the first response and follow-up for leads from one
  # kind of source, turned on with a few answers and editable afterwards.
  #
  # Subclasses are presets (New Facebook lead, Walk-in visit). They supply the
  # sources that start the play, any intake forms it creates, how leads are
  # assigned, and the default content and timing. Everything here is shared, so
  # a fix to how a play is built, customized, drawn or turned off reaches every
  # preset at once.
  #
  # What a dealer edits is `content`, in their own words with a few named
  # fields ({{first_name}}, {{rep_name}}). The workflow and follow-up sequence
  # are generated from it on install and regenerated in place on customize.
  class LeadResponsePlay
    WEEKLY_HOMES_TAG = 'weekly-digest-email'
    MAX_FOLLOW_UP_EMAILS = 8
    REPLY_TASK_DUE_HOURS = 1

    # Named fields a dealer can use in the first text, first email and call
    # task, and what each becomes in the workflow.
    MESSAGE_FIELDS = {
      'first_name' => '{{entity.first_name}}',
      'last_name' => '{{entity.last_name}}',
      'lead_name' => '{{entity.full_name}}',
      'rep_name' => '{{entity.owner_name}}',
      'rep_phone' => '{{entity.owner_phone}}',
      'rep_email' => '{{entity.owner_email}}',
      'booking_link' => '{{rep_booking_link}}',
      'dealership' => :dealership
    }.freeze

    # Follow-up emails are sent by the nurture job, which knows fewer fields.
    FOLLOW_UP_FIELDS = {
      'first_name' => '{{first_name}}',
      'last_name' => '{{last_name}}',
      'dealership' => '{{company_name}}'
    }.freeze

    SAMPLE_VALUES = {
      'first_name' => 'Tia', 'last_name' => 'May', 'lead_name' => 'Tia May',
      'rep_phone' => '(303) 555-0142', 'rep_email' => 'rep@yourdealership.com',
      'booking_link' => 'https://calendly.com/your-rep'
    }.freeze

    FIELD_PATTERN = /\{\{\s*([a-z_]+)\s*\}\}/

    CONTACT_FIELDS = [
      { name: 'First Name', label: 'First Name', type: 'text', required: true, lead_field: 'first_name' },
      { name: 'Last Name', label: 'Last Name', type: 'text', required: true, lead_field: 'last_name' },
      { name: 'Email', label: 'Email', type: 'email', required: true, lead_field: 'email' },
      { name: 'Phone', label: 'Phone', type: 'tel', required: true, lead_field: 'phone' }
    ].freeze

    PREQUALIFICATION_FIELDS = [
      { name: 'Budget', label: 'What budget are you working with?', type: 'text', required: false, lead_field: 'budget_range' },
      { name: 'Timeframe', label: 'When are you hoping to move?', type: 'text', required: false, lead_field: 'purchase_timeframe' }
    ].freeze

    MESSAGE_FIELD = { name: 'Message', label: 'How can we help?', type: 'textarea', required: false, lead_field: 'notes' }.freeze

    # ── Preset hooks ───────────────────────────────────────────────────────

    class << self
      # Lead sources that start the play unless the dealer chooses others.
      def default_sources
        []
      end

      # Intake forms the play creates: [{ name:, source:, fields: :contact | :prequalification }]
      def forms
        []
      end

      # The tag that starts the play when a rep adds it, before the dealer
      # changes it. Each install keeps its own (answers['start_tag']).
      def start_tag
        nil
      end

      # A dealer's tag, as tags are stored: lowercase, words joined by hyphens.
      # Blank means the play has no starting tag.
      def normalize_tag(value)
        value.to_s.strip.downcase.gsub(/\s+/, '-').gsub(/[^a-z0-9_-]/, '').presence
      end

      # The tag that starts this install by hand, for "Start a play".
      def start_tag_for(installation)
        answers_for(installation)['start_tag']
      end

      # :rotation assigns every lead from the rotation. :keep_owner leaves a
      # lead with the rep who entered it and only rotates unassigned ones.
      def assignment
        :rotation
      end

      # Kept registered so an existing install can be seen and turned off,
      # but no longer offered.
      def hidden?
        false
      end

      # A dealer's copy of a play (Plays::PlayCopy) says so, and which play it copies.
      def copy?
        false
      end

      def base_play
        nil
      end

      def default_content
        raise NotImplementedError
      end

      # ── Catalog and display ──────────────────────────────────────────────

      def texting_ready?(company)
        config = CommunicationSettingsService.for_company(company).sms_config
        config[:enabled] != false && config[:from_number].present?
      rescue StandardError
        false
      end

      def kind
        'lead_response'
      end

      # ── Results, shared interface with other kinds of play ───────────────

      def performance_for(installation, period:, location_ids:)
        Plays::Tracking.new(installation: installation, period: period, location_ids: location_ids).summary
      end

      def leads_for(installation, period:, location_ids:, stage:, page:, per_page:)
        Plays::Tracking.new(installation: installation, period: period, location_ids: location_ids)
                       .leads(stage: stage, page: page, per_page: per_page)
      end

      # nil when the lead is not in this play or not visible to the viewer.
      def lead_journey_for(installation, lead, location_ids:)
        place = Plays::Tracking.new(installation: installation, location_ids: location_ids, lead_id: lead.id).place_of(lead.id)
        return nil unless place

        { lead: place.merge(phone: lead.phone), events: Plays::LeadTimeline.new(installation: installation, lead: lead).events.map(&:as_json) }
      end

      def definition(company)
        texting = texting_ready?(company)
        {
          key: self::KEY,
          name: self::NAME,
          description: self::DESCRIPTION,
          kind: kind,
          hidden: hidden?,
          copy_of: copy? ? { key: base_play::KEY, name: base_play::NAME } : nil,
          assignment: assignment.to_s,
          default_sources: default_sources,
          available_sources: company.sources.active.order(:name).pluck(:name).uniq,
          forms: forms.map { |form| form[:name] },
          start_tag: start_tag,
          default_start_tag: start_tag,
          weekly_homes_tag: WEEKLY_HOMES_TAG,
          # Setup offers to turn it on too, since this play tags every lead for it.
          weekly_homes_on: PlayInstallation.active.exists?(company_id: company.id, play_key: WeeklyHomesEmail::KEY),
          texting_ready: texting,
          fields: { messages: MESSAGE_FIELDS.keys, follow_up_emails: FOLLOW_UP_FIELDS.keys },
          default_content: default_content,
          map: map_for(company: company, sources: default_sources, content: normalize_content(nil), rep_names: [], send_texts: texting)
        }
      end

      def installation_json(installation)
        company = installation.company
        answers = answers_for(installation)
        rep_ids = answers['reps_by_location'].values.flatten.uniq
        rep_names = User.where(company_id: company.id, id: rep_ids).map { |u| display_name(u) }

        {
          id: installation.id,
          status: installation.status,
          installed_at: installation.installed_at&.iso8601,
          updated_at: installation.updated_at&.iso8601,
          sources: answers['sources'],
          start_tag: answers['start_tag'],
          reps_by_location: answers['reps_by_location'],
          send_texts: answers['send_texts'],
          content: answers['content'],
          map: map_for(company: company, sources: answers['sources'], content: answers['content'],
                       rep_names: rep_names, send_texts: answers['send_texts'], tag: answers['start_tag']),
          intake_forms: IntakeForm.where(company_id: company.id, id: installation.asset_ids(:intake_form_ids)).map do |form|
            { id: form.id, name: form.name, source: form.source&.name, public_url: form.public_url,
              embed_code: form.embed_code, is_active: form.is_active }
          end,
          workflow_rules: WorkflowRule.where(company_id: company.id, id: installation.asset_ids(:workflow_rule_ids))
                                      .map { |rule| { id: rule.id, name: rule.name, status: rule.status } },
          nurture_sequences: NurtureSequence.where(company_id: company.id, id: installation.asset_ids(:nurture_sequence_ids))
                                            .map { |seq| { id: seq.id, name: seq.name, is_active: seq.is_active } },
          rotations: RoundRobinAssignmentList.where(company_id: company.id, id: installation.asset_ids(:round_robin_list_ids))
                                             .map { |list| { id: list.id, name: list.name, user_ids: list.user_ids, active: list.active } }
        }
      end

      # Stored answers, read the way this preset reads them now. Older installs
      # stored no content and no sources; they get the preset's.
      def answers_for(installation)
        stored = (installation.answers || {}).deep_stringify_keys
        {
          'sources' => Array(stored['sources']).presence || legacy_sources(stored),
          # Installs from before the tag was editable stored none; they keep the preset's.
          'start_tag' => stored.key?('start_tag') ? normalize_tag(stored['start_tag']) : start_tag,
          'reps_by_location' => stored['reps_by_location'] || {},
          'send_texts' => ActiveModel::Type::Boolean.new.cast(stored['send_texts']) || false,
          'content' => normalize_content(stored['content'])
        }
      end

      def legacy_sources(_stored)
        default_sources
      end

      # Turning a play off stops everything it started and leaves the history.
      # Rules are archived and their in-flight runs cancelled, so no message goes
      # out after the dealer said stop. Forms are deactivated rather than
      # deleted, so an embed on a live website shows as unavailable instead of
      # breaking. Tags and sources stay: leads already carry them.
      def uninstall!(installation)
        company_id = installation.company_id
        ActiveRecord::Base.transaction do
          WorkflowRule.where(company_id: company_id, id: installation.asset_ids(:workflow_rule_ids)).find_each do |rule|
            rule.update!(status: 'archived')
            WorkflowRun.where(workflow_rule_id: rule.id, status: %w[pending running waiting]).find_each do |run|
              WorkflowEngine.cancel(run, reason: 'play_turned_off')
            end
          end

          IntakeForm.where(company_id: company_id, id: installation.asset_ids(:intake_form_ids))
                    .update_all(is_active: false, updated_at: Time.current)

          sequence_ids = NurtureSequence.where(company_id: company_id, id: installation.asset_ids(:nurture_sequence_ids)).pluck(:id)
          NurtureSequence.where(id: sequence_ids).update_all(is_active: false, updated_at: Time.current)
          NurtureEnrollment.where(nurture_sequence_id: sequence_ids, status: %w[idle running])
                           .update_all(status: 'paused', updated_at: Time.current)

          RoundRobinAssignmentList.where(company_id: company_id, id: installation.asset_ids(:round_robin_list_ids))
                                  .update_all(active: false, updated_at: Time.current)

          installation.update!(status: 'uninstalled', uninstalled_at: Time.current)
        end
        installation
      end

      # ── Content ──────────────────────────────────────────────────────────

      # Fills in anything missing from the preset's defaults and coerces types.
      def normalize_content(raw)
        defaults = default_content.deep_stringify_keys
        given = (raw || {}).to_h.deep_stringify_keys
        text = defaults['first_text'].merge(given['first_text'].to_h.slice('enabled', 'body'))
        email = defaults['first_email'].merge(given['first_email'].to_h.slice('enabled', 'subject', 'body', 'booking_line', 'signature'))
        call = defaults['call_task'].merge(given['call_task'].to_h.slice('enabled', 'subject', 'due_type', 'due_minutes', 'due_time'))
        follow_ups = given.key?('follow_up_emails') ? Array(given['follow_up_emails']) : defaults['follow_up_emails']

        {
          'first_touch_wait_minutes' => given.fetch('first_touch_wait_minutes', defaults['first_touch_wait_minutes']).to_i,
          'first_text' => { 'enabled' => cast_bool(text['enabled']), 'body' => text['body'].to_s.strip },
          'first_email' => {
            'enabled' => cast_bool(email['enabled']),
            'subject' => email['subject'].to_s.strip,
            'body' => email['body'].to_s.strip,
            'booking_line' => email['booking_line'].to_s.strip,
            'signature' => email['signature'].to_s.strip
          },
          'call_task' => {
            'enabled' => cast_bool(call['enabled']),
            'subject' => call['subject'].to_s.strip,
            'due_type' => %w[minutes next_day].include?(call['due_type'].to_s) ? call['due_type'].to_s : 'minutes',
            'due_minutes' => call['due_minutes'].to_i,
            'due_time' => call['due_time'].to_s.match?(/\A\d{1,2}:\d{2}\z/) ? call['due_time'].to_s : '10:00'
          },
          'reply_wait_hours' => given.fetch('reply_wait_hours', defaults['reply_wait_hours']).to_i,
          'follow_up_emails' => follow_ups.first(MAX_FOLLOW_UP_EMAILS).map do |email_step|
            step = email_step.to_h.deep_stringify_keys
            { 'day' => step['day'].to_i, 'subject' => step['subject'].to_s.strip, 'body' => step['body'].to_s.strip,
              'include_homes' => cast_bool(step['include_homes']) }
          end.sort_by { |step| step['day'] }
        }
      end

      # Raises InstallError with a message the dealer can act on.
      def validate_content!(content)
        wait = content['first_touch_wait_minutes']
        raise InstallError, 'The first message delay must be between 0 and 1440 minutes.' unless (0..1440).cover?(wait)

        text = content['first_text']
        if text['enabled']
          raise InstallError, 'Write the first text, or turn it off.' if text['body'].blank?
          raise InstallError, 'Keep the first text under 480 characters.' if text['body'].length > 480
          check_fields!(text['body'], MESSAGE_FIELDS, 'the first text')
        end

        email = content['first_email']
        if email['enabled']
          raise InstallError, 'Give the first email a subject and a message, or turn it off.' if email['subject'].blank? || email['body'].blank?
          %w[subject body booking_line signature].each { |part| check_fields!(email[part], MESSAGE_FIELDS, 'the first email') }
        end

        call = content['call_task']
        if call['enabled']
          raise InstallError, 'Give the call task a title, or turn it off.' if call['subject'].blank?
          if call['due_type'] == 'minutes' && !(1..1440).cover?(call['due_minutes'])
            raise InstallError, 'The call task must be due within 1 to 1440 minutes.'
          end
          check_fields!(call['subject'], MESSAGE_FIELDS, 'the call task')
        end

        unless (1..168).cover?(content['reply_wait_hours'])
          raise InstallError, 'Wait between 1 and 168 hours for a reply.'
        end

        content['follow_up_emails'].each_with_index do |step, index|
          label = "follow-up email #{index + 1}"
          raise InstallError, "Give #{label} a subject and a message." if step['subject'].blank? || step['body'].blank?
          raise InstallError, "Send #{label} between day 0 and day 120." unless (0..120).cover?(step['day'])
          check_fields!(step['subject'], FOLLOW_UP_FIELDS, label)
          check_fields!(step['body'], FOLLOW_UP_FIELDS, label)
        end
      end

      # ── The map ──────────────────────────────────────────────────────────
      #
      # What the play does, in order, with each message previewed on sample
      # values. Drawn before a play is on (from its defaults) and after (from
      # the dealer's content), so what they see is what runs.
      def map_for(company:, sources:, content:, rep_names:, send_texts:, tag: start_tag)
        sample = SAMPLE_VALUES.merge('rep_name' => rep_names.first || 'Your rep', 'dealership' => company.name)
        steps = []

        trigger_detail = []
        trigger_detail << "Forms: #{forms.map { |f| f[:name] }.join(', ')}" if forms.any?
        trigger_detail << "Or when a rep tags a lead #{tag}" if tag
        steps << { key: 'trigger', kind: 'trigger', title: "New lead from #{Array(sources).join(', ')}",
                   detail: trigger_detail.join('. ').presence }

        assign_detail = if assignment == :keep_owner
                          'Stays with the rep who entered the lead. Unassigned leads go to the next rep in the rotation.'
                        else
                          'The next rep in the rotation at the lead\'s location.'
                        end
        assign_detail += " Rotation: #{rep_names.join(', ')}." if rep_names.any?
        steps << { key: 'assign', kind: 'assign', title: 'Assign a rep', detail: assign_detail }

        if content['first_touch_wait_minutes'].positive?
          steps << { key: 'first_wait', kind: 'wait', title: 'Wait', timing: duration_phrase(content['first_touch_wait_minutes']) }
        end

        if content['first_text']['enabled']
          steps << {
            key: 'first_text', kind: 'text', title: 'Text from the rep',
            condition: send_texts ? 'Only if the lead agreed to texts' : 'Off: texting is not set up for your dealership',
            skipped: !send_texts, preview: fill(content['first_text']['body'], sample)
          }
        end

        if content['first_email']['enabled']
          email = content['first_email']
          body = [email['body'], email['booking_line'], email['signature']].reject(&:blank?).join("\n\n")
          steps << {
            key: 'first_email', kind: 'email', title: 'Email from the rep',
            condition: 'Only if the lead has an email address. The booking link line is left out when the rep has no booking link.',
            subject: fill(email['subject'], sample), preview: fill(body, sample)
          }
        end

        if content['call_task']['enabled']
          call = content['call_task']
          timing = call['due_type'] == 'next_day' ? "Due the next day at #{call['due_time']}" : "Due within #{duration_phrase(call['due_minutes'])}"
          steps << { key: 'call_task', kind: 'task', title: fill(call['subject'], sample), detail: 'Call task for the assigned rep', timing: timing }
        end

        follow_ups = content['follow_up_emails'].each_with_index.map do |step, index|
          { key: "follow_up_#{index + 1}", kind: 'email', title: fill(step['subject'], sample),
            timing: step['day'].zero? ? 'As soon as the wait ends' : "Day #{step['day']} after the wait ends",
            detail: step['include_homes'] ? 'Includes homes matched to the lead' : nil,
            preview: fill(step['body'], sample) }
        end
        follow_ups = [{ key: 'no_follow_up', kind: 'end', title: 'No follow-up emails' }] if follow_ups.empty?

        steps << {
          key: 'reply_wait', kind: 'wait', title: 'Wait for a reply', timing: "Up to #{content['reply_wait_hours']} hours",
          branches: [
            { key: 'replied', label: 'They reply', steps: [
              { key: 'reply_task', kind: 'task', title: 'Follow-up task for the rep', timing: "Due within #{REPLY_TASK_DUE_HOURS} hour" }
            ] },
            { key: 'no_reply', label: 'No reply', note: 'Follow-up emails stop as soon as the lead replies or becomes a deal.', steps: follow_ups }
          ]
        }

        steps << { key: 'weekly_homes', kind: 'tag', title: 'Added to the weekly homes email', detail: "Tagged #{WEEKLY_HOMES_TAG}" }
        steps
      end

      def display_name(user)
        [user.first_name, user.last_name].compact.join(' ').strip.presence || user.email
      end

      private

      def cast_bool(value)
        ActiveModel::Type::Boolean.new.cast(value) || false
      end

      def check_fields!(text, allowed, where)
        unknown = text.to_s.scan(FIELD_PATTERN).flatten.uniq - allowed.keys
        return if unknown.empty?

        raise InstallError, "#{unknown.map { |f| "{{#{f}}}" }.join(', ')} can't be used in #{where}. " \
                            "Available: #{allowed.keys.map { |f| "{{#{f}}}" }.join(', ')}."
      end

      def fill(text, values)
        text.to_s.gsub(FIELD_PATTERN) { values.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
      end

      def duration_phrase(minutes)
        return "#{minutes} minutes" if minutes < 60
        hours = minutes / 60.0
        hours == hours.to_i ? "#{hours.to_i} #{hours.to_i == 1 ? 'hour' : 'hours'}" : "#{minutes} minutes"
      end
    end

    # ── Install and customize ────────────────────────────────────────────

    # answers:
    #   sources:          lead source names that start the play
    #   reps_by_location: { location_id => [user_id, ...] }
    #   send_texts:       only honoured when the company can text
    #   content:          see normalize_content
    def initialize(company:, user:, answers:, installation: nil)
      @company = company
      @user = user
      @answers = (answers || {}).to_h.deep_stringify_keys
      @installation = installation
    end

    def install!
      if PlayInstallation.active.exists?(company_id: @company.id, play_key: self.class::KEY)
        raise InstallError, "#{self.class::NAME} is already on. Customize it instead."
      end
      validate!

      ActiveRecord::Base.transaction do
        source_records = ensure_sources
        ensure_tags
        rotations = sync_rotations({})
        forms = self.class.forms.map { |form| create_form(form) }
        nurture = create_nurture
        sync_nurture_steps(nurture)
        steps = steps_graph(nurture: nurture, rotations: rotations)

        rules = [create_rule("#{self.class::NAME}: new lead", new_lead_trigger, source_conditions(source_records), steps)]
        rules << create_rule("#{self.class::NAME}: tagged #{start_tag}", tag_trigger, tag_conditions, steps) if start_tag

        PlayInstallation.create!(
          company_id: @company.id,
          play_key: self.class::KEY,
          status: 'active',
          answers: stored_answers,
          assets: {
            intake_form_ids: forms.map(&:id),
            workflow_rule_ids: rules.map(&:id),
            nurture_sequence_ids: [nurture.id],
            round_robin_list_ids: rotations.values.map(&:id),
            round_robin_lists: rotations.transform_values(&:id),
            tag_ids: @created_tag_ids || [],
            source_ids: @created_source_ids || []
          },
          installed_by_user_id: @user&.id,
          installed_at: Time.current
        )
      end
    end

    # Regenerates the play's own workflow and follow-up sequence from new
    # answers, in place. A lead already partway through keeps the version it
    # started with (runs carry a snapshot of their steps); new leads get this.
    def customize!
      raise InstallError, "#{self.class::NAME} is not on." unless @installation&.status == 'active'
      validate!

      ActiveRecord::Base.transaction do
        source_records = ensure_sources
        ensure_tags
        assets = (@installation.assets || {}).deep_stringify_keys
        rotations = sync_rotations(assets['round_robin_lists'] || legacy_rotation_ids(assets))

        nurture = NurtureSequence.find_by(company_id: @company.id, id: Array(assets['nurture_sequence_ids']).first) || create_nurture
        nurture.update!(is_active: true, stop_on_reply: true, stop_on_conversion: true)
        sync_nurture_steps(nurture)
        steps = steps_graph(nurture: nurture, rotations: rotations)

        rules = WorkflowRule.where(company_id: @company.id, id: Array(assets['workflow_rule_ids'])).where.not(status: 'archived').to_a
        tag_rule = rules.find { |rule| rule.trigger['event_type'] == 'lead.tagged' }
        (rules - [tag_rule]).each do |rule|
          rule.update!(steps: steps, conditions: source_conditions(source_records))
          ensure_valid!(rule)
        end

        # The starting tag can be added, changed or removed after install.
        rule_ids = Array(assets['workflow_rule_ids'])
        if start_tag && tag_rule
          tag_rule.update!(name: unique_name(@company.workflow_rules.where.not(status: 'archived').where.not(id: tag_rule.id),
                                             "#{self.class::NAME}: tagged #{start_tag}"),
                           steps: steps, conditions: tag_conditions)
          ensure_valid!(tag_rule)
        elsif start_tag
          rule_ids += [create_rule("#{self.class::NAME}: tagged #{start_tag}", tag_trigger, tag_conditions, steps).id]
        elsif tag_rule
          tag_rule.update!(status: 'archived')
        end

        @installation.update!(
          answers: stored_answers,
          assets: assets.merge(
            'workflow_rule_ids' => rule_ids.uniq,
            'nurture_sequence_ids' => [nurture.id],
            'round_robin_list_ids' => (Array(assets['round_robin_list_ids']) + rotations.values.map(&:id)).uniq,
            'round_robin_lists' => rotations.transform_values(&:id)
          )
        )
      end
      @installation
    end

    private

    # ── Answers ──────────────────────────────────────────────────────────

    def validate!
      raise InstallError, 'Choose at least one lead source that starts this play.' if sources.empty?
      raise InstallError, 'Choose at least one rep to receive new leads.' if reps_by_location.values.flatten.empty?

      claimed = claimed_sources
      overlap = sources & claimed.keys
      if overlap.any?
        raise InstallError, "#{overlap.join(', ')} already starts #{claimed[overlap.first]}. " \
                            'A lead can only start one play, or it would get two first messages.'
      end

      if start_tag == WEEKLY_HOMES_TAG
        raise InstallError, "#{WEEKLY_HOMES_TAG} is the weekly homes email tag, and this play adds it to every lead. Choose another starting tag."
      end
      if start_tag && (other = claimed_tags[start_tag])
        raise InstallError, "The tag #{start_tag} already starts #{other}. Choose another tag, or change it on that play first."
      end

      self.class.validate_content!(content)
    end

    # nil when the play has no starting tag.
    def start_tag
      return @start_tag if defined?(@start_tag)

      @start_tag = @answers.key?('start_tag') ? self.class.normalize_tag(@answers['start_tag']) : self.class.start_tag
    end

    # Starting tags other active plays use, tag => play name.
    def claimed_tags
      PlayInstallation.active.where(company_id: @company.id).where.not(id: @installation&.id).each_with_object({}) do |installation, acc|
        play = Plays::Registry.find(installation.play_key, company: installation.company_id)
        tag = play.respond_to?(:start_tag_for) && play.kind == 'lead_response' ? play.start_tag_for(installation) : nil
        acc[tag] = play::NAME if tag
      end
    end

    def sources
      @sources ||= begin
        given = Array(@answers['sources']).map { |name| name.to_s.strip }.reject(&:blank?).uniq
        given.presence || (@answers.key?('sources') ? [] : self.class.default_sources)
      end
    end

    # Sources other active plays already start from, name => play name.
    def claimed_sources
      PlayInstallation.active.where(company_id: @company.id).where.not(id: @installation&.id).each_with_object({}) do |installation, acc|
        play = Plays::Registry.find(installation.play_key, company: installation.company_id)
        next unless play

        play.answers_for(installation)['sources'].each { |name| acc[name] = play::NAME }
      end
    end

    # Only this company's active, non-corporate locations and active users
    # count. The corporate location is usually an administrative shell no rep
    # works. Anything else in the answers is dropped, never trusted.
    def reps_by_location
      @reps_by_location ||= begin
        given = @answers['reps_by_location'] || {}
        locations = @company.locations.active.where(is_corporate: false, id: given.keys.map(&:to_i)).index_by(&:id)
        given.each_with_object({}) do |(location_id, user_ids), acc|
          location = locations[location_id.to_i]
          next unless location

          ids = Array(user_ids).map(&:to_i)
          active = User.where(company_id: @company.id, status: 'active', id: ids).pluck(:id)
          kept = ids & active
          acc[location] = kept if kept.any?
        end
      end
    end

    def send_texts?
      return @send_texts if defined?(@send_texts)

      @send_texts = ActiveModel::Type::Boolean.new.cast(@answers.fetch('send_texts', true)) && self.class.texting_ready?(@company)
    end

    def content
      @content ||= self.class.normalize_content(@answers['content'])
    end

    def stored_answers
      {
        sources: sources,
        start_tag: start_tag,
        reps_by_location: reps_by_location.to_h { |location, ids| [location.id.to_s, ids] },
        send_texts: send_texts?,
        content: content
      }
    end

    # ── Records ──────────────────────────────────────────────────────────

    def ensure_sources
      sources.map do |name|
        source = @company.sources.find_or_create_by!(name: name) { |s| s.is_active = true }
        (@created_source_ids ||= []) << source.id if source.previously_new_record?
        source
      end
    end

    def ensure_tags
      [start_tag, WEEKLY_HOMES_TAG].compact.each do |name|
        tag = @company.tags.find_or_create_by!(name: name) do |t|
          t.color = '#0F766E'
          t.is_active = true
          t.is_system = false
        end
        (@created_tag_ids ||= []) << tag.id if tag.previously_new_record?
      end
    end

    # One rotation per location when leads come from more than one, plus a
    # company-wide rotation of every chosen rep for a lead with no location.
    # Existing rotations are updated rather than replaced, so a rotation keeps
    # its place in line across edits.
    def sync_rotations(existing_ids)
      existing_ids = (existing_ids || {}).transform_keys(&:to_s)
      desired = { 'all' => ['All locations', reps_by_location.values.flatten.uniq] }
      if reps_by_location.size > 1
        reps_by_location.each { |location, ids| desired[location.id.to_s] = [location.name, ids] }
      end

      rotations = desired.to_h do |key, (label, user_ids)|
        list = RoundRobinAssignmentList.find_by(company_id: @company.id, id: existing_ids[key])
        if list
          list.update!(user_ids: user_ids, active: true)
        else
          list = RoundRobinAssignmentList.create!(
            company_id: @company.id, user_ids: user_ids, active: true,
            name: unique_name(RoundRobinAssignmentList.where(company_id: @company.id), "#{self.class::NAME} rotation: #{label}")
          )
        end
        [key, list]
      end

      (existing_ids.keys - rotations.keys).each do |key|
        RoundRobinAssignmentList.where(company_id: @company.id, id: existing_ids[key]).update_all(active: false, updated_at: Time.current)
      end
      rotations
    end

    def legacy_rotation_ids(assets)
      ids = Array(assets['round_robin_list_ids'])
      ids.any? ? { 'all' => ids.last } : {}
    end

    def create_form(form)
      fields = CONTACT_FIELDS.dup
      fields += PREQUALIFICATION_FIELDS if form[:fields] == :prequalification
      fields += [MESSAGE_FIELD, sms_consent_field]

      schema = fields.each_with_index.map do |field, index|
        {
          'id' => SecureRandom.uuid, 'name' => field[:name], 'label' => field[:label], 'type' => field[:type],
          'required' => field[:required], 'placeholder' => field[:placeholder].to_s, 'order' => index + 1,
          'isActive' => true, 'leadField' => field[:lead_field], 'consentText' => field[:consent_text]
        }.compact
      end

      source = @company.sources.find_or_create_by!(name: form[:source]) { |s| s.is_active = true }
      only_location = reps_by_location.size == 1 ? reps_by_location.keys.first : nil

      @company.intake_forms.create!(
        name: unique_name(@company.intake_forms, form[:name]),
        description: "Created by the #{self.class::NAME} play.",
        schema: schema,
        field_mappings: schema.to_h { |f| [f['name'], f['leadField']] },
        source_id: source.id,
        location_id: only_location&.id,
        # Whoever set the play up hears about each new lead; the rep it is
        # assigned to gets the call task.
        notified_user_id: @user&.id,
        is_active: true,
        auto_create_lead: true,
        # The play creates its own call task for the assigned rep.
        auto_create_activity: false,
        submit_button_text: 'Send',
        thank_you_message: "Thanks for reaching out. Someone from #{@company.name} will be in touch shortly."
      )
    end

    # Texts need consent. The play only texts a lead who ticked this box.
    # 'consent' renders as a checkbox labelled by the placeholder, with the
    # consent text in a box beneath it, on both public form renderers.
    def sms_consent_field
      {
        name: 'Text Me', label: 'Text messages', placeholder: 'Text me about my inquiry', type: 'consent',
        required: false, lead_field: 'opt_in_sms',
        consent_text: "By checking this box you agree to receive text messages from #{@company.name} about your inquiry. " \
                      'Message and data rates may apply. Reply STOP to opt out.'
      }
    end

    # Email only: a nurture step does not check text consent, so it never texts.
    def create_nurture
      @company.nurture_sequences.create!(
        name: unique_name(@company.nurture_sequences, "#{self.class::NAME} follow-up"),
        description: "Follow-up emails for a lead who has not replied. Created by the #{self.class::NAME} play.",
        is_active: true,
        stop_on_reply: true,
        stop_on_conversion: true
      )
    end

    # A nurture runs its first step the moment a lead is enrolled, and each
    # later step's wait_days is the delay after the one before. So a first
    # email on day 3 needs a leading wait step. Steps are updated in place by
    # position so an enrollment already in progress keeps its place.
    def sync_nurture_steps(sequence)
      emails = content['follow_up_emails']
      desired = []
      desired << { step_type: 'wait', wait_days: 0, subject: nil, body: nil, include_inventory: false } if emails.any? && emails.first['day'].positive?

      previous_day = 0
      emails.each do |email|
        desired << {
          step_type: 'email', channel: 'email', wait_days: email['day'] - previous_day,
          subject: follow_up_text(email['subject']), body: follow_up_html(email['body']),
          include_inventory: email['include_homes']
        }
        previous_day = email['day']
      end

      existing = sequence.nurture_steps.order(:position).to_a
      desired.each_with_index do |attrs, index|
        step = existing[index] || sequence.nurture_steps.new
        step.assign_attributes(attrs.merge(position: index + 1))
        step.save!
      end
      existing.drop(desired.size).each(&:destroy!)
    end

    def create_rule(name, trigger, conditions, steps)
      rule = @company.workflow_rules.create!(
        name: unique_name(@company.workflow_rules.where.not(status: 'archived'), name),
        description: "Created by the #{self.class::NAME} play.",
        entity_type: 'Lead',
        status: 'draft',
        trigger: trigger,
        conditions: conditions,
        steps: steps,
        parameters: {},
        halt_on_reply: 'false',
        created_by_user_id: @user&.id
      )
      ensure_valid!(rule)
      rule.update!(status: 'active')
      rule
    end

    def ensure_valid!(rule)
      validation = WorkflowRuleValidator.new(rule).validate
      return if validation.valid?

      raise InstallError, "The play could not switch on #{rule.name}: #{validation.errors.first}"
    end

    def new_lead_trigger
      { 'event_type' => 'lead.created', 'entity_type_filter' => 'Lead' }
    end

    def tag_trigger
      { 'event_type' => 'lead.tagged', 'entity_type_filter' => 'Lead' }
    end

    def source_conditions(source_records)
      [{ 'field' => 'source.name', 'operator' => 'in', 'value' => source_records.map(&:name) }]
    end

    def tag_conditions
      [{ 'field' => 'trigger.tag_name', 'operator' => 'equals', 'value' => start_tag }]
    end

    def unique_name(scope, base)
      return base unless scope.exists?(name: base)

      (2..100).each do |n|
        candidate = "#{base} (#{n})"
        return candidate unless scope.exists?(name: candidate)
      end
      "#{base} #{SecureRandom.hex(2)}"
    end

    # ── The workflow ─────────────────────────────────────────────────────
    #
    # assign -> [wait] -> text if consented -> email (with the rep's booking
    # line when they have a link) -> call task -> wait for a reply ->
    #   replied:  follow-up task
    #   no reply: follow-up emails
    # -> weekly homes tag
    def steps_graph(nurture:, rotations:)
      @nodes = []
      @edges = []
      after_assignment = first_touch_entry

      location_rotations = rotations.except('all').map { |id, list| [id.to_i, list] }
      rotation_entry = location_rotations.any? ? "at_location_#{location_rotations.first[0]}" : 'assign_all'

      if self.class.assignment == :keep_owner
        branch('has_owner', { 'field' => 'entity.owner_id', 'operator' => 'is_set' }, after_assignment, rotation_entry)
      end

      location_rotations.each_with_index do |(location_id, list), index|
        check = "at_location_#{location_id}"
        assign = "assign_location_#{location_id}"
        otherwise = location_rotations[index + 1] ? "at_location_#{location_rotations[index + 1][0]}" : 'assign_all'
        branch(check, { 'field' => 'entity.location_id', 'operator' => 'equals', 'value' => location_id }, assign, otherwise)
        node(assign, 'assign_owner', { 'strategy' => 'round_robin_list', 'round_robin_list_id' => list.id }, after_assignment)
      end
      node('assign_all', 'assign_owner', { 'strategy' => 'round_robin_list', 'round_robin_list_id' => rotations.fetch('all').id }, after_assignment)

      if content['first_touch_wait_minutes'].positive?
        node('first_wait', 'wait', { 'duration' => content['first_touch_wait_minutes'], 'unit' => 'minutes' }, text_entry)
      end

      if texting?
        branch('consent', { 'field' => 'entity.opt_in_sms', 'operator' => 'equals', 'value' => true }, 'text_hello', email_entry)
        node('text_hello', 'send_sms', { 'to' => '{{entity.phone}}', 'body' => message_text(content['first_text']['body']) }, email_entry)
      end

      if content['first_email']['enabled']
        email = content['first_email']
        branch('has_email', { 'field' => 'entity.email', 'operator' => 'is_set' }, 'has_booking_link', call_entry)
        branch('has_booking_link', { 'field' => 'entity_hash.owner_booking_url', 'operator' => 'is_set' }, 'email_with_booking', 'email_hello')
        subject = message_text(email['subject'])
        node('email_with_booking', 'send_email',
             { 'to' => '{{entity.email}}', 'subject' => subject, 'body' => first_email_html(booking: true) }, call_entry)
        node('email_hello', 'send_email',
             { 'to' => '{{entity.email}}', 'subject' => subject, 'body' => first_email_html(booking: false) }, call_entry)
      end

      if content['call_task']['enabled']
        call = content['call_task']
        due = if call['due_type'] == 'next_day'
                { 'due_in_days' => 1, 'due_time' => call['due_time'] }
              else
                { 'due_in_minutes' => call['due_minutes'] }
              end
        node('call_task', 'create_activity', {
          'activity_type' => 'call',
          'subject' => message_text(call['subject']),
          'description' => 'Created by the play. Phone: {{entity.phone}}. Email: {{entity.email}}.',
          'priority' => 'high',
          'assigned_to' => 'owner'
        }.merge(due), 'wait_reply')
      end

      no_reply = content['follow_up_emails'].any? ? 'start_follow_up' : 'tag_weekly_homes'
      node('wait_reply', 'wait_for_reply',
           { 'timeout_hours' => content['reply_wait_hours'], 'on_reply_branch' => 'reply_task', 'on_timeout_branch' => no_reply })
      edge('wait_reply', 'reply_task')
      edge('wait_reply', no_reply)

      node('reply_task', 'create_activity', {
        'activity_type' => 'task',
        'subject' => '{{entity.first_name}} replied: follow up',
        'description' => 'A new lead replied to their first message. Pick the conversation back up.',
        'due_in_hours' => REPLY_TASK_DUE_HOURS,
        'priority' => 'high',
        'assigned_to' => 'owner'
      }, 'tag_weekly_homes')
      if content['follow_up_emails'].any?
        node('start_follow_up', 'enroll_in_nurture', { 'nurture_sequence_id' => nurture.id }, 'tag_weekly_homes')
      end
      node('tag_weekly_homes', 'add_tag', { 'tag_names' => [WEEKLY_HOMES_TAG] })

      # A run starts at the first node, so order of creation matters above:
      # keep_owner's check, then the location checks, then assign_all.
      { 'nodes' => @nodes, 'edges' => @edges }
    end

    def texting?
      send_texts? && content['first_text']['enabled']
    end

    def first_touch_entry
      return 'first_wait' if content['first_touch_wait_minutes'].positive?

      text_entry
    end

    def text_entry
      texting? ? 'consent' : email_entry
    end

    def email_entry
      content['first_email']['enabled'] ? 'has_email' : call_entry
    end

    def call_entry
      content['call_task']['enabled'] ? 'call_task' : 'wait_reply'
    end

    def node(id, type, config, next_id = nil)
      @nodes << { 'id' => id, 'type' => type, 'config' => config }
      edge(id, next_id) if next_id
    end

    # Branch targets live in config; the edges only let the canvas draw them.
    def branch(id, condition, on_true, on_false)
      node(id, 'branch', { 'condition' => condition, 'on_true_branch' => on_true, 'on_false_branch' => on_false })
      edge(id, on_true)
      edge(id, on_false)
    end

    def edge(from, to)
      @edges << { 'id' => "e_#{from}_#{to}", 'source' => from, 'target' => to }
    end

    # ── Rendering the dealer's words ─────────────────────────────────────

    # Workflow runs have no {{company.*}}, so the dealer's name is written in.
    def message_text(text)
      text.to_s.gsub(FIELD_PATTERN) do
        target = MESSAGE_FIELDS.fetch(Regexp.last_match(1))
        target == :dealership ? @company.name : target
      end
    end

    def first_email_html(booking:)
      email = content['first_email']
      parts = [email['body']]
      parts << email['booking_line'] if booking && email['booking_line'].present?
      parts << email['signature'] if email['signature'].present?

      paragraphs(parts.join("\n\n")).gsub(FIELD_PATTERN) do
        field = Regexp.last_match(1)
        case field
        when 'dealership' then ERB::Util.html_escape(@company.name)
        when 'booking_link' then '<a href="{{rep_booking_link}}">{{rep_booking_link}}</a>'
        else MESSAGE_FIELDS.fetch(field)
        end
      end
    end

    def follow_up_text(text)
      text.to_s.gsub(FIELD_PATTERN) { FOLLOW_UP_FIELDS.fetch(Regexp.last_match(1)) }
    end

    def follow_up_html(text)
      follow_up_text(paragraphs(text))
    end

    # Plain text to HTML: a blank line starts a paragraph, a single line break
    # stays a line break, and a web address becomes a link (a video, a price
    # sheet). Escaped first, so a dealer's "<" is never markup.
    def paragraphs(text)
      ERB::Util.html_escape(text.to_s).split(/\n{2,}/).map { |p| "<p>#{link_urls(p.strip).gsub("\n", '<br>')}</p>" }.join
    end

    WEB_ADDRESS = %r{https?://[^\s<>"]+}

    # Runs on escaped text. Punctuation that ends a sentence stays outside the link.
    def link_urls(html)
      html.gsub(WEB_ADDRESS) do |match|
        url = match.sub(/[.,;:!?)]+\z/, '')
        trailing = match[url.length..]
        %(<a href="#{url}">#{url}</a>#{trailing})
      end
    end
  end
end
