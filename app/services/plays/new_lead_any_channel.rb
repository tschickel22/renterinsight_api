# frozen_string_literal: true

module Plays
  # "New lead, any channel", the flagship starter play.
  #
  # A dealer answers a few questions and gets the whole first response already
  # switched on: an intake form per channel, a rep rotation per location, an
  # instant text and email from the assigned rep, a call task, a wait for a
  # reply, then a two week nurture and the weekly homes tag.
  #
  # Facebook is one channel among several. A lead starts the play from any
  # intake form it creates, from an intake API key posting with one of its
  # sources, or when a rep tags a hand-entered lead "follow-up".
  class NewLeadAnyChannel
    KEY = 'new_lead_any_channel'
    NAME = 'New lead, any channel'
    DESCRIPTION = 'Every new lead gets a text and email from their rep within a minute, a call task, ' \
                  'and a two week follow-up if they do not reply. Works for website, Google, Facebook ' \
                  'and pre-qualification forms, and for leads your reps enter by hand.'

    FOLLOW_UP_TAG = 'follow-up'
    WEEKLY_HOMES_TAG = 'weekly-digest-email'
    CALL_WITHIN_OPTIONS = [5, 15, 30, 60].freeze
    DEFAULT_CALL_WITHIN = 15
    REPLY_WAIT_HOURS = 24

    CHANNELS = {
      'website' => { label: 'Website contact', form_name: 'Website Contact', source: 'Website' },
      'prequalification' => { label: 'Pre-qualification', form_name: 'Pre-Qualification', source: 'Pre-Qualification' },
      'google' => { label: 'Google', form_name: 'Google Contact', source: 'Google' },
      'facebook' => { label: 'Facebook', form_name: 'Facebook Contact', source: 'Facebook' }
    }.freeze

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

    def self.texting_ready?(company)
      config = CommunicationSettingsService.for_company(company).sms_config
      config[:enabled] != false && config[:from_number].present?
    rescue StandardError
      false
    end

    # What the install dialog needs to ask its questions.
    def self.definition(company)
      {
        key: KEY,
        name: NAME,
        description: DESCRIPTION,
        channels: CHANNELS.map { |key, channel| { key: key, label: channel[:label] } },
        call_within_options: CALL_WITHIN_OPTIONS,
        default_call_within: DEFAULT_CALL_WITHIN,
        texting_ready: texting_ready?(company)
      }
    end

    def self.installation_json(installation)
      company_id = installation.company_id
      {
        id: installation.id,
        status: installation.status,
        answers: installation.answers,
        installed_at: installation.installed_at&.iso8601,
        intake_forms: IntakeForm.where(company_id: company_id, id: installation.asset_ids(:intake_form_ids)).map do |form|
          { id: form.id, name: form.name, source: form.source&.name, public_url: form.public_url,
            embed_code: form.embed_code, is_active: form.is_active }
        end,
        workflow_rules: WorkflowRule.where(company_id: company_id, id: installation.asset_ids(:workflow_rule_ids))
                                    .map { |rule| { id: rule.id, name: rule.name, status: rule.status } },
        nurture_sequences: NurtureSequence.where(company_id: company_id, id: installation.asset_ids(:nurture_sequence_ids))
                                          .map { |seq| { id: seq.id, name: seq.name, is_active: seq.is_active } },
        rotations: RoundRobinAssignmentList.where(company_id: company_id, id: installation.asset_ids(:round_robin_list_ids))
                                           .map { |list| { id: list.id, name: list.name, user_ids: list.user_ids } }
      }
    end

    # Turning a play off stops everything it started and leaves the history.
    # Rules are archived and their in-flight runs cancelled, so no text goes
    # out after the dealer said stop. Forms are deactivated rather than deleted
    # so an embed on a live website shows as unavailable instead of breaking.
    # Tags and sources stay: leads already carry them.
    def self.uninstall!(installation)
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

    # answers:
    #   channels:            keys of CHANNELS
    #   reps_by_location:    { location_id => [user_id, ...] }
    #   call_within_minutes: one of CALL_WITHIN_OPTIONS
    #   send_texts:          only honoured when the company can text
    def initialize(company:, user:, answers:)
      @company = company
      @user = user
      @answers = (answers || {}).to_h.deep_stringify_keys
    end

    def install!
      validate!

      ActiveRecord::Base.transaction do
        sources = channels.to_h { |key| [key, find_or_create_source(CHANNELS.fetch(key)[:source])] }
        tags = [FOLLOW_UP_TAG, WEEKLY_HOMES_TAG].map { |name| find_or_create_tag(name) }
        rotations = create_rotations
        forms = channels.map { |key| create_form(key, sources.fetch(key)) }
        nurture = create_nurture
        steps = steps_graph(nurture: nurture, rotations: rotations)

        rules = [
          create_rule(
            name: "#{NAME}: new lead",
            trigger: { 'event_type' => 'lead.created', 'entity_type_filter' => 'Lead' },
            conditions: [{ 'field' => 'source.name', 'operator' => 'in', 'value' => sources.values.map(&:name) }],
            steps: steps
          ),
          create_rule(
            name: "#{NAME}: tagged #{FOLLOW_UP_TAG}",
            trigger: { 'event_type' => 'lead.tagged', 'entity_type_filter' => 'Lead' },
            conditions: [{ 'field' => 'trigger.tag_name', 'operator' => 'equals', 'value' => FOLLOW_UP_TAG }],
            steps: steps
          )
        ]

        PlayInstallation.create!(
          company_id: @company.id,
          play_key: KEY,
          status: 'active',
          answers: normalized_answers,
          assets: {
            intake_form_ids: forms.map(&:id),
            workflow_rule_ids: rules.map(&:id),
            nurture_sequence_ids: [nurture.id],
            round_robin_list_ids: rotations.values.map(&:id),
            tag_ids: @created_tag_ids || [],
            source_ids: @created_source_ids || []
          },
          installed_by_user_id: @user&.id,
          installed_at: Time.current
        )
      end
    end

    private

    # ── Answers ────────────────────────────────────────────────────────────

    def validate!
      if PlayInstallation.active.exists?(company_id: @company.id, play_key: KEY)
        raise InstallError, "#{NAME} is already on. Turn it off before setting it up again."
      end
      raise InstallError, 'Choose at least one channel.' if channels.empty?
      raise InstallError, 'Choose at least one rep to receive new leads.' if reps_by_location.values.flatten.empty?
    end

    def channels
      @channels ||= Array(@answers['channels']).map(&:to_s).select { |key| CHANNELS.key?(key) }.uniq
    end

    # Only this company's active locations and active users count. Anything
    # else in the answers is dropped, never trusted.
    def reps_by_location
      @reps_by_location ||= begin
        locations = @company.locations.active.where(id: (@answers['reps_by_location'] || {}).keys.map(&:to_i)).index_by(&:id)
        (@answers['reps_by_location'] || {}).each_with_object({}) do |(location_id, user_ids), acc|
          location = locations[location_id.to_i]
          next unless location

          ids = User.where(company_id: @company.id, status: 'active', id: Array(user_ids).map(&:to_i)).pluck(:id)
          acc[location] = Array(user_ids).map(&:to_i) & ids
        end.reject { |_location, ids| ids.empty? }
      end
    end

    def call_within_minutes
      value = @answers['call_within_minutes'].to_i
      CALL_WITHIN_OPTIONS.include?(value) ? value : DEFAULT_CALL_WITHIN
    end

    def send_texts?
      @send_texts ||= ActiveModel::Type::Boolean.new.cast(@answers.fetch('send_texts', true)) &&
                      self.class.texting_ready?(@company)
    end

    def normalized_answers
      {
        channels: channels,
        reps_by_location: reps_by_location.to_h { |location, ids| [location.id.to_s, ids] },
        call_within_minutes: call_within_minutes,
        send_texts: send_texts?
      }
    end

    # ── Records ────────────────────────────────────────────────────────────

    def find_or_create_source(name)
      source = @company.sources.find_or_create_by!(name: name) { |s| s.is_active = true }
      (@created_source_ids ||= []) << source.id if source.previously_new_record?
      source
    end

    def find_or_create_tag(name)
      tag = @company.tags.find_or_create_by!(name: name) do |t|
        t.color = '#0F766E'
        t.is_active = true
        t.is_system = false
      end
      (@created_tag_ids ||= []) << tag.id if tag.previously_new_record?
      tag
    end

    # One rotation per location when leads come from more than one, plus a
    # company-wide rotation of every chosen rep for a lead with no location.
    def create_rotations
      rotations = {}
      if reps_by_location.size > 1
        reps_by_location.each do |location, ids|
          rotations[location] = create_rotation("New lead rotation: #{location.name}", ids)
        end
      end
      rotations[:all] = create_rotation('New lead rotation: all locations', reps_by_location.values.flatten.uniq)
      rotations
    end

    def create_rotation(name, user_ids)
      RoundRobinAssignmentList.create!(company_id: @company.id, name: unique_name(RoundRobinAssignmentList.where(company_id: @company.id), name),
                                       user_ids: user_ids, active: true)
    end

    def create_form(key, source)
      channel = CHANNELS.fetch(key)
      fields = CONTACT_FIELDS.dup
      fields += PREQUALIFICATION_FIELDS if key == 'prequalification'
      fields += [MESSAGE_FIELD, sms_consent_field]

      schema = fields.each_with_index.map do |field, index|
        {
          'id' => SecureRandom.uuid, 'name' => field[:name], 'label' => field[:label], 'type' => field[:type],
          'required' => field[:required], 'placeholder' => field[:placeholder].to_s, 'order' => index + 1,
          'isActive' => true, 'leadField' => field[:lead_field], 'consentText' => field[:consent_text]
        }.compact
      end

      only_location = reps_by_location.size == 1 ? reps_by_location.keys.first : nil

      @company.intake_forms.create!(
        name: unique_name(@company.intake_forms, channel[:form_name]),
        description: "Created by the #{NAME} play.",
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
    def sms_consent_field
      # 'consent' renders as a checkbox labelled by the placeholder, with the
      # consent text shown in a box beneath it, on both public form renderers.
      {
        name: 'Text Me', label: 'Text messages', placeholder: 'Text me about my inquiry', type: 'consent',
        required: false, lead_field: 'opt_in_sms',
        consent_text: "By checking this box you agree to receive text messages from #{@company.name} about your inquiry. " \
                      'Message and data rates may apply. Reply STOP to opt out.'
      }
    end

    # Email only: a nurture step does not check text consent, so it never texts.
    def create_nurture
      sequence = @company.nurture_sequences.create!(
        name: unique_name(@company.nurture_sequences, 'New lead follow-up'),
        description: "Two weeks of follow-up for a new lead who has not replied. Created by the #{NAME} play.",
        is_active: true,
        stop_on_reply: true,
        stop_on_conversion: true
      )

      [
        { position: 1, wait_days: 0, subject: 'Still looking for the right home, {{first_name}}?',
          body: '<p>Hi {{first_name}},</p><p>I wanted to follow up on your inquiry with {{company_name}}. ' \
                'Whether you are just starting to look or ready to tour, we are happy to help at your pace.</p>' \
                '<p>Reply to this email with any questions, or let us know a good time to talk.</p>' },
        { position: 2, wait_days: 4, subject: 'A few homes we think you will like', include_inventory: true,
          body: '<p>Hi {{first_name}},</p><p>Here are a few homes on our lot right now that could be a good fit. ' \
                'If one catches your eye, reply and we will set up a time for you to see it in person.</p>' },
        { position: 3, wait_days: 6, subject: 'Should we keep in touch, {{first_name}}?',
          body: '<p>Hi {{first_name}},</p><p>I do not want to crowd your inbox. If you are still thinking about a new home, ' \
                'reply and tell me what you are looking for and I will send options that fit. ' \
                'If now is not the right time, that is completely fine.</p>' }
      ].each do |step|
        sequence.nurture_steps.create!(step.merge(step_type: 'email', channel: 'email'))
      end

      sequence
    end

    def create_rule(name:, trigger:, conditions:, steps:)
      rule = @company.workflow_rules.create!(
        name: unique_name(@company.workflow_rules.where.not(status: 'archived'), name),
        description: "Created by the #{NAME} play.",
        entity_type: 'Lead',
        status: 'draft',
        trigger: trigger,
        conditions: conditions,
        steps: steps,
        parameters: {},
        halt_on_reply: 'false',
        created_by_user_id: @user&.id
      )

      validation = WorkflowRuleValidator.new(rule).validate
      unless validation.valid?
        raise InstallError, "The play could not switch on #{rule.name}: #{validation.errors.first}"
      end

      rule.update!(status: 'active')
      rule
    end

    def unique_name(scope, base)
      return base unless scope.exists?(name: base)

      (2..100).each do |n|
        candidate = "#{base} (#{n})"
        return candidate unless scope.exists?(name: candidate)
      end
      "#{base} #{SecureRandom.hex(2)}"
    end

    # ── The workflow ───────────────────────────────────────────────────────
    #
    # assign by location -> text if consented -> email (with the rep's booking
    # link when they have one) -> call task -> wait for a reply ->
    #   replied:  follow-up task
    #   no reply: two week nurture
    # -> weekly homes tag
    def steps_graph(nurture:, rotations:)
      @nodes = []
      @edges = []
      after_assignment = send_texts? ? 'consent' : 'has_email'

      location_rotations = rotations.reject { |key, _list| key == :all }.to_a
      location_rotations.each_with_index do |(location, list), index|
        check = "at_location_#{location.id}"
        assign = "assign_location_#{location.id}"
        otherwise = location_rotations[index + 1] ? "at_location_#{location_rotations[index + 1][0].id}" : 'assign_all'
        branch(check, { 'field' => 'entity.location_id', 'operator' => 'equals', 'value' => location.id }, assign, otherwise)
        node(assign, 'assign_owner', { 'strategy' => 'round_robin_list', 'round_robin_list_id' => list.id }, after_assignment)
      end
      node('assign_all', 'assign_owner', { 'strategy' => 'round_robin_list', 'round_robin_list_id' => rotations[:all].id }, after_assignment)

      if send_texts?
        branch('consent', { 'field' => 'entity.opt_in_sms', 'operator' => 'equals', 'value' => true }, 'text_hello', 'has_email')
        node('text_hello', 'send_sms', { 'to' => '{{entity.phone}}', 'body' => hello_text }, 'has_email')
      end

      branch('has_email', { 'field' => 'entity.email', 'operator' => 'is_set' }, 'has_booking_link', 'call_task')
      branch('has_booking_link', { 'field' => 'entity_hash.owner_booking_url', 'operator' => 'is_set' }, 'email_with_booking', 'email_hello')
      node('email_with_booking', 'send_email',
           { 'to' => '{{entity.email}}', 'subject' => hello_subject, 'body' => hello_email(booking: true) }, 'call_task')
      node('email_hello', 'send_email',
           { 'to' => '{{entity.email}}', 'subject' => hello_subject, 'body' => hello_email(booking: false) }, 'call_task')

      node('call_task', 'create_activity', {
        'activity_type' => 'call',
        'subject' => 'Call new lead {{entity.full_name}}',
        'description' => "Reach out within #{call_within_minutes} minutes. Phone: {{entity.phone}}. Email: {{entity.email}}.",
        'due_in_minutes' => call_within_minutes,
        'priority' => 'high',
        'assigned_to' => 'owner'
      }, 'wait_reply')

      node('wait_reply', 'wait_for_reply',
           { 'timeout_hours' => REPLY_WAIT_HOURS, 'on_reply_branch' => 'reply_task', 'on_timeout_branch' => 'start_nurture' })
      edge('wait_reply', 'reply_task')
      edge('wait_reply', 'start_nurture')

      node('reply_task', 'create_activity', {
        'activity_type' => 'task',
        'subject' => '{{entity.first_name}} replied: follow up',
        'description' => 'A new lead replied to their first message. Pick the conversation back up.',
        'due_in_hours' => 1,
        'priority' => 'high',
        'assigned_to' => 'owner'
      }, 'tag_weekly_homes')
      node('start_nurture', 'enroll_in_nurture', { 'nurture_sequence_id' => nurture.id }, 'tag_weekly_homes')
      node('tag_weekly_homes', 'add_tag', { 'tag_names' => [WEEKLY_HOMES_TAG] })

      { 'nodes' => @nodes, 'edges' => @edges }
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

    # Workflow runs have no {{company.*}}, so the dealer's name is written in.
    def hello_text
      "Hi {{entity.first_name}}, this is {{entity.owner_name}} with #{@company.name}. Thanks for reaching out! " \
        'I will give you a call shortly, or reply here with any questions.'
    end

    def hello_subject
      'Thanks for reaching out, {{entity.first_name}}'
    end

    def hello_email(booking:)
      company = ERB::Util.html_escape(@company.name)
      next_step = if booking
                    '<p>I will give you a call soon. If it is easier, <a href="{{rep_booking_link}}">pick a time that works for you</a>.</p>'
                  else
                    '<p>I will give you a call soon, or you can reply to this email with any questions.</p>'
                  end
      "<p>Hi {{entity.first_name}},</p><p>Thanks for contacting #{company}. I am {{entity.owner_name}}, " \
        "and I will be your point of contact.</p>#{next_step}<p>Talk soon,<br>{{entity.owner_name}}<br>{{entity.owner_phone}}</p>"
    end
  end
end
