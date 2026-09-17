# frozen_string_literal: true

module Plays
  # How a play that is on is doing: where each lead is right now, how many sit
  # at each step, and whether it works (reached, replied, called, booked,
  # became a deal).
  #
  # Read from records the play already creates, nothing new is written: its
  # workflow runs and the steps they executed, the follow-up enrollment, the
  # call tasks it made, inbound messages, meetings and conversion. A lead that
  # started the play more than once (a new lead, then tagged) is counted once,
  # by its latest run.
  class Tracking
    PERIODS = { '30' => 30, '90' => 90, 'all' => nil }.freeze
    DEFAULT_PERIOD = '90'

    FIRST_MESSAGE_STEPS = %w[text_hello email_with_booking email_hello].freeze

    # %{lead} is the dealer's own word for a lead. "Waiting for a reply" read
    # as though the rep owed one, when the messages have gone out and it is the
    # lead's turn.
    STAGES = {
      'first_response' => 'Getting a first response',
      'waiting_for_reply' => 'Waiting for the %{lead} to reply',
      'replied' => 'Replied',
      'follow_up' => 'In follow-up emails',
      'follow_up_done' => 'Follow-up finished',
      'became_deal' => 'Became a deal',
      'stopped' => 'Stopped'
    }.freeze

    # A run's current step, as the step on the play's map.
    MAP_STEP = {
      'first_wait' => 'first_wait', 'consent' => 'first_text', 'text_hello' => 'first_text',
      'has_email' => 'first_email', 'has_booking_link' => 'first_email',
      'email_with_booking' => 'first_email', 'email_hello' => 'first_email',
      'call_task' => 'call_task', 'wait_reply' => 'reply_wait', 'reply_task' => 'reply_task'
    }.freeze

    Entry = Struct.new(:run, :lead, :stage, :detail, :detail_at, :map_step, keyword_init: true)

    # location_ids: nil for every location, or the locations this viewer may see.
    # lead_id:      limit to one lead (for its journey), across all time.
    # Stage names in the dealer's own words ("Waiting for the guest to reply").
    def self.stage_labels(company)
      word = company&.resolved_labels&.[]('lead').presence || 'lead'
      STAGES.transform_values { |label| format(label, lead: word.downcase) }
    end

    def initialize(installation:, period: DEFAULT_PERIOD, location_ids: nil, lead_id: nil, now: Time.current)
      @installation = installation
      @company_id = installation.company_id
      @period = lead_id ? 'all' : (PERIODS.key?(period.to_s) ? period.to_s : DEFAULT_PERIOD)
      @location_ids = location_ids&.map(&:to_i)
      @lead_id = lead_id&.to_i
      @now = now
    end

    attr_reader :period

    # Where one lead is now, or nil when it is not in this play (or not visible).
    def place_of(lead_id)
      entry = entries.find { |e| e.lead.id == lead_id.to_i }
      entry && lead_json(entry)
    end

    def summary
      entries = self.entries
      {
        period: @period,
        stages: stage_labels.map { |key, label| { key: key, label: label } },
        stage_counts: STAGES.keys.to_h { |stage| [stage, entries.count { |e| e.stage == stage }] },
        step_counts: entries.filter_map(&:map_step).tally,
        metrics: metrics(entries)
      }
    end

    def leads(stage: nil, page: 1, per_page: 25)
      list = entries
      list = list.select { |e| e.stage == stage.to_s } if STAGES.key?(stage.to_s)
      per_page = per_page.to_i.clamp(1, 100)
      page = [page.to_i, 1].max
      total = list.size
      items = list.sort_by { |e| e.run.started_at || e.run.created_at }.reverse.slice((page - 1) * per_page, per_page) || []

      {
        items: items.map { |entry| lead_json(entry) },
        meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil }
      }
    end

    private

    # ── Loading ──────────────────────────────────────────────────────────

    def entries
      @entries ||= begin
        runs = latest_runs
        lead_ids = runs.map(&:entity_id)
        lead_scope = Lead.where(company_id: @company_id, id: lead_ids)
        lead_scope = lead_scope.where(location_id: @location_ids) if @location_ids
        leads = lead_scope.includes(:source, :owner).index_by(&:id)
        load_related(runs, lead_ids)

        runs.filter_map do |run|
          lead = leads[run.entity_id]
          next unless lead

          stage, detail, detail_at, map_step = place(run, lead)
          Entry.new(run: run, lead: lead, stage: stage, detail: detail, detail_at: detail_at, map_step: map_step)
        end
      end
    end

    def latest_runs
      scope = WorkflowRun.where(company_id: @company_id, entity_type: 'Lead', workflow_rule_id: @installation.asset_ids(:workflow_rule_ids))
      scope = scope.where('workflow_runs.started_at >= ?', @now - PERIODS[@period].days) if PERIODS[@period]
      scope = scope.where(entity_id: @lead_id) if @lead_id
      scope.order(started_at: :desc, id: :desc).to_a.uniq(&:entity_id)
    end

    def load_related(runs, lead_ids)
      run_ids = runs.map(&:id)
      @steps = WorkflowRunStep.where(workflow_run_id: run_ids)
                              .order(:created_at)
                              .pluck(:workflow_run_id, :step_id, :status, :created_at, :output)
                              .group_by(&:first)

      @inbound_at = Communication.where(communicable_type: 'Lead', communicable_id: lead_ids, direction: 'inbound')
                                 .group(:communicable_id).maximum(:created_at)

      call_ids = @steps.values.flatten(1).filter_map { |(_, step_id, status, _, output)| output['id'] if step_id == 'call_task' && status == 'success' }
      @calls = LeadActivity.where(id: call_ids).pluck(:id, :status, :created_at, :completed_at).to_h { |row| [row[0], row] }

      @meeting_at = LeadActivity.where(lead_id: lead_ids, activity_type: 'meeting').group(:lead_id).maximum(:created_at)

      sequence_id = @installation.asset_ids(:nurture_sequence_ids).first
      @follow_up_types = NurtureStep.where(nurture_sequence_id: sequence_id).order(:position).pluck(:step_type)
      @enrollments = NurtureEnrollment.where(nurture_sequence_id: sequence_id)
                                      .where('(enrollable_type = ? AND enrollable_id IN (?)) OR lead_id IN (?)', 'Lead', lead_ids.presence || [0], lead_ids.presence || [0])
                                      .order(:created_at)
                                      .to_a
                                      .index_by { |e| e.enrollable_id || e.lead_id }
    end

    # ── Where a lead is ──────────────────────────────────────────────────

    # [stage, detail, detail_at, map_step]
    def place(run, lead)
      started = run.started_at || run.created_at
      steps = steps_for(run)

      if lead.is_converted && (lead.converted_at.nil? || lead.converted_at >= started)
        return ['became_deal', 'Converted to a deal', lead.converted_at, nil]
      end
      return ['stopped', 'The play was turned off', run.completed_at, nil] if run.status == 'cancelled'
      if run.status == 'failed'
        return ['stopped', "Stopped at #{step_label(run.current_step_id)} because of an error", run.completed_at, nil]
      end
      return ['replied', 'Replied to the play', @inbound_at[lead.id], 'reply_task'] if replied?(lead, started)

      case run.status
      when 'waiting'
        if run.wait_reason == 'reply_pause'
          ['waiting_for_reply', 'Moves to follow-up emails if no reply by', run.wait_until, 'reply_wait']
        else
          ['first_response', 'First message goes out at', run.wait_until, MAP_STEP.fetch(run.current_step_id, 'assign')]
        end
      when 'pending', 'running'
        ['first_response', 'Sending the first messages', nil, MAP_STEP.fetch(run.current_step_id.to_s, 'assign')]
      else
        follow_up_place(lead, steps)
      end
    end

    def follow_up_place(lead, steps)
      enrollment = @enrollments[lead.id]
      unless enrollment && steps.any? { |(_, step_id)| step_id == 'start_follow_up' }
        return ['follow_up_done', 'Finished the play', nil, nil]
      end

      email_count = @follow_up_types.count('email')
      case enrollment.status
      when 'completed'
        ['follow_up_done', "All #{email_count} follow-up emails sent", enrollment.updated_at, nil]
      when 'paused'
        ['stopped', 'Follow-up emails were paused', enrollment.updated_at, nil]
      else
        next_index = enrollment.current_step_index.to_i
        sent = @follow_up_types.first(next_index).count('email')
        number = [sent + 1, email_count].min
        ["follow_up", "Next: follow-up email #{number} of #{email_count}", nil, "follow_up_#{number}"]
      end
    end

    def replied?(lead, started)
      at = @inbound_at[lead.id]
      at.present? && at >= started
    end

    def steps_for(run)
      @steps[run.id] || []
    end

    def step_label(step_id)
      {
        'text_hello' => 'the first text', 'email_with_booking' => 'the first email', 'email_hello' => 'the first email',
        'call_task' => 'the call task', 'wait_reply' => 'the reply wait', 'start_follow_up' => 'the follow-up emails'
      }.fetch(step_id.to_s, 'assignment')
    end

    # ── Results ──────────────────────────────────────────────────────────

    def metrics(entries)
      started = entries.size
      first_message_minutes = entries.filter_map do |entry|
        sent = steps_for(entry.run).find { |(_, step_id, status)| FIRST_MESSAGE_STEPS.include?(step_id) && status == 'success' }
        sent && minutes_between(entry.run.started_at || entry.run.created_at, sent[3])
      end

      calls = entries.filter_map do |entry|
        step = steps_for(entry.run).find { |(_, step_id, status)| step_id == 'call_task' && status == 'success' }
        step && @calls[step[4]['id']]
      end
      completed_calls = calls.select { |(_, status, _, completed_at)| status == 'completed' && completed_at }

      replied = entries.count { |e| replied?(e.lead, e.run.started_at || e.run.created_at) }
      booked = entries.count do |e|
        at = @meeting_at[e.lead.id]
        at.present? && at >= (e.run.started_at || e.run.created_at)
      end
      deals = entries.count { |e| e.stage == 'became_deal' }

      {
        leads_started: started,
        reached: first_message_minutes.size,
        reached_rate: rate(first_message_minutes.size, started),
        median_minutes_to_first_message: median(first_message_minutes),
        replied: replied,
        reply_rate: rate(replied, started),
        call_tasks: calls.size,
        calls_completed: completed_calls.size,
        call_completion_rate: rate(completed_calls.size, calls.size),
        median_minutes_to_call: median(completed_calls.map { |(_, _, created_at, completed_at)| minutes_between(created_at, completed_at) }),
        appointments: booked,
        deals: deals,
        deal_rate: rate(deals, started)
      }
    end

    def stage_labels
      @stage_labels ||= self.class.stage_labels(@installation.company)
    end

    def lead_json(entry)
      lead = entry.lead
      {
        lead_id: lead.id,
        name: [lead.first_name, lead.last_name].compact.join(' ').strip.presence || lead.email || "Lead ##{lead.id}",
        email: lead.email,
        source: lead.source&.name,
        rep: lead.owner && LeadResponsePlay.display_name(lead.owner),
        started_at: (entry.run.started_at || entry.run.created_at)&.iso8601,
        stage: entry.stage,
        stage_label: stage_labels.fetch(entry.stage),
        detail: entry.detail,
        detail_at: entry.detail_at&.iso8601
      }
    end

    def minutes_between(from, to)
      return nil if from.nil? || to.nil?

      ((to - from) / 60.0).round(1)
    end

    def median(values)
      sorted = values.compact.sort
      return nil if sorted.empty?

      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round(1)
    end

    def rate(part, whole)
      whole.zero? ? nil : (part.to_f / whole).round(3)
    end
  end
end
