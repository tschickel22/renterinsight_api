# frozen_string_literal: true

module PhoneCalls
  # Records one finished call reported by a dealer's phone system (3CX's call
  # journaling) and puts it on the Activities tab of the lead, contact or account
  # that owns the outside number.
  #
  # - Every report lands in phone_call_logs, matched or not. A call from a number
  #   nobody in the CRM has is kept there and does NOT create a lead: plenty of
  #   calls are vendors, factories and robocalls. 3CX's own "create contact"
  #   option is the route for turning a caller into a lead.
  # - 3CX sends no call id, so a resent report is recognised by a key built from
  #   the number, start time, extension and call type.
  # - The activity is credited to the DealerTide user whose email or name matches
  #   the 3CX extension; failing that the record's owner, failing that an admin
  #   (activities require a user).
  # - A missed call from someone already in the CRM tells their owner and
  #   followers, because 3CX's own missed-call emails need a mail server many
  #   dealers never set up.
  class Recorder
    # 3CX [CallType] => [direction, outcome]
    CALL_TYPES = {
      'inbound' => %w[inbound answered],
      'outbound' => %w[outbound answered],
      'missed' => %w[inbound no_answer],
      'notanswered' => %w[outbound no_answer]
    }.freeze

    Result = Struct.new(:log, :record, :activity, :duplicate, keyword_init: true)

    def initialize(company:, provider: '3cx')
      @company = company
      @provider = provider
    end

    # attrs: call_type, direction, number, agent, agent_email, agent_name,
    # duration (seconds or hh:mm:ss), started_at, entity_id. Values 3CX left as an
    # unfilled "[Variable]" placeholder count as blank.
    def call(attrs, payload: {})
      a = clean(attrs)
      direction, outcome = classify(a)
      started = parse_time(a[:started_at])
      key = dedupe_key(a, started)

      existing = @company.phone_call_logs.find_by(dedupe_key: key)
      return Result.new(log: existing, record: existing.loggable, duplicate: true) if existing

      record = resolve_record(a)
      user = resolve_user(a, record)
      log = @company.phone_call_logs.create!(
        provider: @provider, dedupe_key: key, call_type: a[:call_type], direction: direction, outcome: outcome,
        number: a[:number], agent: a[:agent], agent_name: a[:agent_name], agent_email: a[:agent_email],
        user_id: user&.id, started_at: started, duration_seconds: parse_duration(a[:duration]),
        loggable: record, payload: payload
      )
      activity = record && user ? create_activity!(log, record, user) : nil
      log.update_columns(activity_type: activity.class.name, activity_id: activity.id) if activity
      notify_missed(log, record) if record && direction == 'inbound' && outcome == 'no_answer'
      Result.new(log: log, record: record, activity: activity, duplicate: false)
    rescue ActiveRecord::RecordNotUnique
      existing = @company.phone_call_logs.find_by(dedupe_key: key)
      Result.new(log: existing, record: existing&.loggable, duplicate: true)
    end

    private

    def clean(attrs)
      attrs.to_h.transform_keys(&:to_sym).transform_values do |v|
        s = v.to_s.strip
        s.match?(/\A\[[^\]]*\]\z/) ? nil : s.presence
      end
    end

    def classify(a)
      mapped = CALL_TYPES[a[:call_type].to_s.downcase]
      return mapped if mapped

      dir = a[:direction].to_s.downcase.start_with?('out') ? 'outbound' : 'inbound'
      [dir, parse_duration(a[:duration]).to_i.positive? ? 'answered' : 'no_answer']
    end

    def dedupe_key(a, started)
      parts = [@provider, a[:number].to_s.gsub(/\D/, '').last(10), started&.utc&.iso8601 || a[:started_at],
               a[:agent], a[:call_type] || a[:direction]]
      Digest::SHA256.hexdigest(parts.join('|'))
    end

    def resolve_record(a)
      lookup = Lookup.new(@company)
      from_entity = a[:entity_id] && lookup.find_entity(a[:entity_id])
      return from_entity if from_entity

      lookup.resolve(a[:number])&.last
    end

    def resolve_user(a, record)
      users = @company.users.where(status: 'active')
      by_email = a[:agent_email] && users.where('LOWER(email) = ?', a[:agent_email].downcase).first
      return by_email if by_email

      if a[:agent_name].present?
        first, last = a[:agent_name].split(/\s+/, 2)
        by_name = users.where('LOWER(first_name) = ? AND LOWER(COALESCE(last_name, \'\')) = ?',
                              first.to_s.downcase, last.to_s.downcase).first
        return by_name if by_name
      end

      owner_id = record.try(:owner_id)
      owner = owner_id && users.find_by(id: owner_id)
      owner || users.order(:id).detect(&:effective_admin?)
    end

    def create_activity!(log, record, user)
      started = log.started_at || Time.current
      secs = log.duration_seconds.to_i
      attrs = {
        user: user, activity_type: 'call', subject: subject(log), description: description(log),
        status: 'completed', completed_at: started + secs.seconds, start_time: started,
        duration_minutes: secs.positive? ? (secs / 60.0).ceil : 0,
        call_direction: log.direction, call_outcome: log.outcome, phone_number: log.number,
        metadata: { 'source' => @provider, 'phone_call_log_id' => log.id, 'extension' => log.agent,
                    'call_type' => log.call_type }.compact,
        remind_customer: false, send_calendar_invite: false
      }
      case record
      when Lead then record.lead_activities.create!(attrs)
      when Contact then record.contact_activities.create!(attrs)
      when Account then record.activities.create!(attrs)
      end
    end

    def subject(log)
      base = case [log.direction, log.outcome]
             when %w[inbound answered] then 'Incoming call'
             when %w[outbound answered] then 'Outgoing call'
             when %w[inbound no_answer] then 'Missed call'
             else 'Unanswered outgoing call'
             end
      secs = log.duration_seconds.to_i
      secs.positive? ? "#{base} (#{duration_label(secs)})" : base
    end

    def description(log)
      who = log.agent_name.presence || (log.agent && "extension #{log.agent}")
      phone_word = @provider == '3cx' ? '3CX' : @provider
      [who && "Handled by #{who}", "Logged by #{phone_word}"].compact.join('. ') + '.'
    end

    def duration_label(secs)
      m, s = secs.divmod(60)
      m.zero? ? "#{s} sec" : "#{m} min #{s} sec"
    end

    def notify_missed(log, record)
      recipients = record.respond_to?(:notify_audience) ? record.notify_audience(except: nil) : []
      owner = record.try(:owner_id) && @company.users.find_by(id: record.owner_id)
      recipients = ([owner] + recipients).compact.uniq
      label = record.try(:full_name).presence || record.try(:name).presence ||
              [record.try(:first_name), record.try(:last_name)].compact.join(' ').strip.presence || log.number
      recipients.each do |user|
        NotificationService.create(
          recipient: user, notification_type: :missed_call, notifiable: record,
          message: "Missed call from #{label} (#{log.number})", company_id: @company.id,
          action_text: 'View Record'
        )
      end
    rescue StandardError => e
      Rails.logger.error "[PhoneCalls::Recorder] missed call notify failed for log #{log.id}: #{e.class}: #{e.message}"
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    # "95", "95.4", "00:01:35" or "1.00:01:35" (a .NET TimeSpan)
    def parse_duration(value)
      s = value.to_s.strip
      return nil if s.blank?
      return s.to_f.round if s.match?(/\A\d+(\.\d+)?\z/)

      days = 0
      if (m = s.match(/\A(\d+)\.(\d+:\d+:\d+)/))
        days = m[1].to_i
        s = m[2]
      end
      parts = s.split(':').map(&:to_f)
      return nil unless parts.length.between?(2, 3)

      parts.unshift(0) if parts.length == 2
      (days * 86_400 + parts[0] * 3600 + parts[1] * 60 + parts[2]).round
    end
  end
end
