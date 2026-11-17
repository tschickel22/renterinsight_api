# frozen_string_literal: true

module PhoneCalls
  # Records one text conversation reported by a dealer's phone system (3CX's
  # chat journaling, the ReportChat scenario) and puts it on the conversation of
  # the lead, contact or account that owns the outside number.
  #
  # How 3CX sends it, and what follows from that:
  # - One report per conversation, when someone marks it dealt with in 3CX. Not
  #   per message and not in real time; a conversation left open never arrives.
  # - The text comes as one string, [ChatMessages], in a shape 3CX does not
  #   document (no per-message time or direction). So the whole transcript is
  #   saved as ONE inbound SMS entry on the record, and the raw report is kept
  #   in phone_call_logs (call_type "sms") so a parser into separate messages
  #   can be written against real reports later.
  # - 3CX sends no chat id. A report is recognised by number + chat start; the
  #   same conversation reported again (reopened, more messages) updates the
  #   saved transcript instead of adding a second one.
  # - A number nobody has becomes a lead when create_lead is on (the template's
  #   "Create a lead for unknown numbers"), via LeadMaker, and the people who
  #   get "New lead by text" hear about it, as for a text to a DealerTide number.
  # - A STOP from the customer is honoured: 3CX records it on its side only, and
  #   DealerTide must not text that person afterwards (CommunicationOptOut, and
  #   campaign suppression).
  class ChatRecorder
    STOP_WORDS = %w[stop stopall unsubscribe cancel quit end optout opt-out].freeze

    Result = Struct.new(:log, :record, :communication, :duplicate, :created_lead, :opted_out, keyword_init: true)

    def initialize(company:, provider: '3cx')
      @company = company
      @provider = provider
    end

    # attrs: number, messages, agent, agent_email, agent_name, duration,
    # started_at, ended_at, entity_id, create_lead ("True"/"False").
    def call(attrs, payload: {})
      a = clean(attrs)
      started = parse_time(a[:started_at])
      key = dedupe_key(a, started)

      existing = @company.phone_call_logs.find_by(dedupe_key: key)
      return update_existing(existing, a, payload) if existing

      record = resolve_record(a)
      created = false
      if record.nil? && truthy?(a[:create_lead])
        record = LeadMaker.new(@company).create!(number: a[:number], kind: :text, note: first_contact_note(a))
        created = record.present?
      end
      user = resolve_user(a, record)

      log = nil
      comm = nil
      ActiveRecord::Base.transaction do
        log = @company.phone_call_logs.create!(
          provider: @provider, dedupe_key: key, call_type: 'sms', direction: 'inbound',
          number: a[:number], agent: a[:agent], agent_name: a[:agent_name], agent_email: a[:agent_email],
          user_id: user&.id, started_at: started, duration_seconds: Recorder.parse_duration(a[:duration]),
          loggable: record, payload: payload
        )
        comm = create_communication!(log, record, user, a) if record && a[:messages].present?
        log.update_columns(activity_type: comm.class.name, activity_id: comm.id) if comm
      end
      notify_new_lead(record, a) if created
      opted = record && opt_out_if_stopped(record, a)
      Result.new(log: log, record: record, communication: comm, duplicate: false, created_lead: created, opted_out: opted)
    rescue ActiveRecord::RecordNotUnique
      existing = @company.phone_call_logs.find_by(dedupe_key: key)
      Result.new(log: existing, record: existing&.loggable, duplicate: true, created_lead: false, opted_out: false)
    end

    private

    def update_existing(log, a, payload)
      comm = log.activity_type == 'Communication' ? Communication.find_by(id: log.activity_id) : nil
      if a[:messages].present? && log.payload['messages'].to_s != a[:messages]
        log.update!(payload: payload, duration_seconds: Recorder.parse_duration(a[:duration]))
        if comm
          comm.update!(body: a[:messages])
        elsif log.loggable
          comm = create_communication!(log, log.loggable, log.user, a)
          log.update_columns(activity_type: comm.class.name, activity_id: comm.id)
        end
      end
      opted = log.loggable && opt_out_if_stopped(log.loggable, a)
      Result.new(log: log, record: log.loggable, communication: comm, duplicate: true, created_lead: false, opted_out: opted)
    end

    def create_communication!(log, record, user, a)
      at = log.started_at || Time.current
      Communication.create!(
        company_id: @company.id, communicable: record, channel: 'sms', direction: 'inbound',
        provider: @provider, from_address: a[:number],
        # 3CX does not say which of the dealer's numbers the conversation was on.
        to_address: @provider == '3cx' ? '3CX' : @provider, body: a[:messages],
        status: 'delivered', sent_at: at, delivered_at: at, received_at: at, user_id: user&.id,
        metadata: { 'source' => @provider, 'transcript' => true, 'phone_call_log_id' => log.id,
                    'extension' => log.agent, 'agent_name' => log.agent_name,
                    'ended_at' => parse_time(a[:ended_at])&.iso8601 }.compact
      )
    end

    def clean(attrs)
      attrs.to_h.transform_keys(&:to_sym).transform_values do |v|
        s = v.to_s.strip
        s.match?(/\A\[[^\]]*\]\z/) ? nil : s.presence
      end
    end

    def truthy?(value)
      value.to_s.strip.casecmp('true').zero?
    end

    def dedupe_key(a, started)
      parts = [@provider, 'sms', a[:number].to_s.gsub(/\D/, '').last(10), started&.utc&.iso8601 || a[:started_at]]
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
      owner_id && users.find_by(id: owner_id)
    end

    def first_contact_note(a)
      text = a[:messages].to_s.squish.truncate(300)
      "First contact by text through the phone system from #{a[:number]}#{text.present? ? ": #{text}" : '.'}"
    end

    # A line of the transcript that is only a stop word, with or without a
    # "name:" or "[time] name:" in front of it.
    def stopped?(messages)
      messages.to_s.each_line.any? do |line|
        text = line.strip
        [text, text.split(':').last.to_s].any? do |candidate|
          STOP_WORDS.include?(candidate.strip.downcase.delete_suffix('.').delete_suffix('!'))
        end
      end
    end

    def opt_out_if_stopped(record, a)
      return false unless stopped?(a[:messages])

      pref = CommunicationPreference.find_or_create_for(recipient: record, channel: 'sms')
      pref.opt_out!('STOP in a text conversation reported by the phone system') unless pref.opted_out?
      phone = Campaigns::SmsInboundHandler.normalize_phone(a[:number])
      Campaigns::SmsInboundHandler.handle_stop(@company.id, phone, nil) if LeadMaker.full_number?(phone)
      true
    rescue StandardError => e
      Rails.logger.error "[PhoneCalls::ChatRecorder] opt-out failed for #{record.class.name} #{record.id}: #{e.class}: #{e.message}"
      false
    end

    def notify_new_lead(lead, a)
      recipients = lead.respond_to?(:notify_audience) ? lead.notify_audience(except: nil) : []
      owner = lead.owner_id && @company.users.find_by(id: lead.owner_id)
      recipients = ([owner] + recipients).compact.uniq
      recipients = @company.users.where(status: 'active').select(&:effective_admin?) if recipients.empty?
      text = a[:messages].to_s.squish.truncate(120)
      recipients.each do |user|
        NotificationService.create(
          recipient: user, notification_type: :sms_new_lead, notifiable: lead,
          message: "New lead by text from #{LeadMaker.pretty(a[:number])}#{text.present? ? ": #{text}" : ''}",
          company_id: @company.id, action_text: 'View Lead'
        )
      end
    rescue StandardError => e
      Rails.logger.error "[PhoneCalls::ChatRecorder] notify failed for lead #{lead.id}: #{e.class}: #{e.message}"
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
