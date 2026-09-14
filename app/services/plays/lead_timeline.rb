# frozen_string_literal: true

module Plays
  # One lead's journey through a play, in order: when it started, who it went
  # to, each message and whether it was opened, the call task and whether the
  # rep made the call, the reply wait, the reply, follow-up emails, an
  # appointment, and becoming a deal.
  #
  # Built from the play's own records, so it shows what actually happened
  # rather than what the play intended.
  class LeadTimeline
    Event = Struct.new(:at, :kind, :title, :detail, keyword_init: true) do
      def as_json(*)
        { at: at&.iso8601, kind: kind, title: title, detail: detail }
      end
    end

    TRIGGER_TITLES = { 'lead.created' => 'Started the play as a new lead', 'lead.tagged' => 'Started the play when tagged' }.freeze

    def initialize(installation:, lead:)
      @installation = installation
      @lead = lead
      @company_id = installation.company_id
    end

    def events
      runs = WorkflowRun.where(company_id: @company_id, entity_type: 'Lead', entity_id: @lead.id,
                               workflow_rule_id: @installation.asset_ids(:workflow_rule_ids))
                        .includes(:workflow_rule, :workflow_run_steps)
                        .order(:started_at, :id)
                        .to_a
      return [] if runs.empty?

      started = runs.first.started_at || runs.first.created_at
      events = runs.flat_map { |run| run_events(run) }
      events.concat(reply_events(started))
      events.concat(follow_up_email_events)
      events.concat(appointment_events(started))
      if @lead.is_converted && @lead.converted_at && @lead.converted_at >= started
        events << Event.new(at: @lead.converted_at, kind: 'deal', title: 'Became a deal')
      end
      events.sort_by { |e| e.at || Time.zone.at(0) }
    end

    private

    def run_events(run)
      list = [Event.new(at: run.started_at || run.created_at, kind: 'trigger',
                        title: TRIGGER_TITLES.fetch(run.workflow_rule&.trigger&.dig('event_type'), 'Started the play'))]
      run.workflow_run_steps.sort_by(&:created_at).each { |step| list.concat(step_events(run, step)) }
      if run.status == 'cancelled'
        list << Event.new(at: run.completed_at || run.updated_at, kind: 'stopped', title: 'Stopped: the play was turned off')
      end
      list
    end

    def step_events(run, step)
      output = step.output || {}
      at = step.created_at

      if step.status == 'failed'
        return [Event.new(at: at, kind: 'stopped', title: "Stopped at #{STEP_NAMES.fetch(step.step_id, 'a step')}",
                          detail: step.error&.dig('message'))]
      end

      case step.step_id
      when /\Aassign/
        return [] unless output['owner_id']
        [Event.new(at: at, kind: 'assign', title: "Assigned to #{user_name(output['owner_id'])}")]
      when 'has_owner'
        output['branch_taken'] == 'true' ? [Event.new(at: at, kind: 'assign', title: 'Kept with the rep who entered it')] : []
      when 'first_wait'
        [Event.new(at: at, kind: 'wait', title: 'Waiting before the first message', detail: until_text(output['wait_until']))]
      when 'consent'
        output['branch_taken'] == 'false' ? [Event.new(at: at, kind: 'skipped', title: 'Not texted: the lead did not agree to texts')] : []
      when 'has_email'
        output['branch_taken'] == 'false' ? [Event.new(at: at, kind: 'skipped', title: 'No email sent: the lead has no email address')] : []
      when 'text_hello'
        [Event.new(at: at, kind: 'text', title: 'Text sent', detail: output['to'])]
      when 'email_with_booking', 'email_hello'
        email_events(at, output['communication_id'], 'First email sent')
      when 'call_task', 'reply_task'
        task_events(step.step_id, at, output['id'])
      when 'wait_reply'
        wait_events(run, at, output)
      when 'start_follow_up'
        step.status == 'success' ? [Event.new(at: at, kind: 'follow_up', title: 'Follow-up emails started')] : []
      when 'tag_weekly_homes'
        step.status == 'success' ? [Event.new(at: at, kind: 'tag', title: 'Added to the weekly homes email')] : []
      else
        []
      end
    end

    STEP_NAMES = {
      'text_hello' => 'the first text', 'email_with_booking' => 'the first email', 'email_hello' => 'the first email',
      'call_task' => 'the call task', 'reply_task' => 'the follow-up task', 'wait_reply' => 'the reply wait',
      'start_follow_up' => 'the follow-up emails', 'assign_all' => 'assignment'
    }.freeze

    def email_events(at, communication_id, title)
      communication = communication_id && Communication.find_by(id: communication_id, communicable_type: 'Lead', communicable_id: @lead.id)
      list = [Event.new(at: at, kind: 'email', title: title, detail: communication&.subject)]
      list.concat(engagement_events(communication)) if communication
      list
    end

    def engagement_events(communication)
      events = CommunicationEvent.where(communication_id: communication.id, event_type: %w[opened clicked])
                                 .group(:event_type).minimum(:occurred_at)
      list = []
      list << Event.new(at: events['opened'], kind: 'opened', title: 'Opened the email', detail: communication.subject) if events['opened']
      list << Event.new(at: events['clicked'], kind: 'clicked', title: 'Clicked a link in the email', detail: communication.subject) if events['clicked']
      list
    end

    def task_events(step_id, at, activity_id)
      activity = activity_id && LeadActivity.find_by(id: activity_id, lead_id: @lead.id)
      return [] unless activity

      created = if step_id == 'call_task'
                  "Call task for #{user_name(activity.assigned_to_id)}"
                else
                  "Follow-up task for #{user_name(activity.assigned_to_id)}"
                end
      list = [Event.new(at: at, kind: 'task', title: created, detail: activity.due_date && "Due #{activity.due_date.iso8601}")]
      if activity.status == 'completed' && activity.completed_at
        list << Event.new(at: activity.completed_at, kind: 'task_done',
                          title: step_id == 'call_task' ? 'Call completed' : 'Follow-up task completed')
      end
      list
    end

    def wait_events(run, at, output)
      case output['branch']
      when 'timeout'
        [Event.new(at: at, kind: 'wait', title: 'No reply in time: moving to follow-up emails')]
      when 'reply'
        []
      else
        detail = run.status == 'waiting' && run.wait_reason == 'reply_pause' ? until_text(run.wait_until) : nil
        [Event.new(at: at, kind: 'wait', title: 'Waiting for a reply', detail: detail)]
      end
    end

    def reply_events(started)
      Communication.where(communicable_type: 'Lead', communicable_id: @lead.id, direction: 'inbound')
                   .where('created_at >= ?', started)
                   .order(:created_at)
                   .limit(20)
                   .map do |message|
        channel = message.channel == 'sms' ? 'text' : message.channel
        Event.new(at: message.created_at, kind: 'reply', title: "Replied by #{channel}",
                  detail: message.body.to_s.squish.truncate(140))
      end
    end

    def follow_up_email_events
      sequence_id = @installation.asset_ids(:nurture_sequence_ids).first
      return [] unless sequence_id

      Communication.where(communicable_type: 'Lead', communicable_id: @lead.id, direction: 'outbound', channel: 'email')
                   .where("metadata->>'nurture_sequence_id' = ?", sequence_id.to_s)
                   .order(:created_at)
                   .flat_map do |communication|
        at = communication.sent_at || communication.created_at
        [Event.new(at: at, kind: 'email', title: 'Follow-up email sent', detail: communication.subject)] +
          engagement_events(communication)
      end
    end

    def appointment_events(started)
      LeadActivity.where(lead_id: @lead.id, activity_type: 'meeting').where('created_at >= ?', started).order(:created_at).map do |meeting|
        Event.new(at: meeting.created_at, kind: 'appointment', title: 'Appointment booked',
                  detail: meeting.start_time && "For #{meeting.start_time.iso8601}")
      end
    end

    def user_name(user_id)
      user = user_id && User.find_by(id: user_id, company_id: @company_id)
      user ? LeadResponsePlay.display_name(user) : 'a rep'
    end

    def until_text(time)
      parsed = time.is_a?(String) ? Time.zone.parse(time) : time
      parsed && "Until #{parsed.iso8601}"
    rescue ArgumentError
      nil
    end
  end
end
