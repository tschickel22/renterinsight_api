# frozen_string_literal: true

module Appointments
  # Mail sent to an appointment's tracked reply address
  # (reply+appt-lead-415@...): the organizer address on its calendar invites
  # and the Reply-To on the customer's copy. That covers:
  # - a calendar response (Accept, Decline, Maybe, often with a note), and
  # - a plain reply to the invite email.
  #
  # Either way the customer's answer is recorded on the appointment, shown on
  # their timeline, and relayed to the rep it is assigned to (bell, email,
  # text, toast; InboundEmail::ReplyNotifier). The rep answering their own
  # copy is recorded only.
  class InviteReplyHandler
    STATUS_WORDS = { 'accepted' => 'accepted', 'declined' => 'declined', 'tentative' => 'tentatively accepted' }.freeze

    def self.process(token:, parsed_email:)
      new(token, parsed_email).process
    end

    def initialize(token, parsed_email)
      @token = token
      @email = parsed_email
    end

    def process
      activity = CalendarInvite.activity_for_token(@token)
      return { success: false, error: "Appointment not found for #{@token}" } unless activity

      invite = CalendarInvite.new(activity)
      @activity = activity
      @customer = invite.customer
      @rep = invite.assignee
      response = calendar_response
      from = (response && response[:email]) || @email[:from].to_s.downcase

      record_response(from, response) if response
      if from_rep?(from)
        return { success: true, source: 'appointment_reply', recorded_only: true }
      end
      return { success: false, error: 'Appointment has no customer record' } unless @customer

      communication = log(response)
      InboundEmail::ReplyNotifier.notify(entity: @customer.record, communication: communication, outbound_communication: rep_outbound)
      { success: true, source: 'appointment_reply', communication_id: communication.id, response: response&.dig(:status) }
    rescue StandardError => e
      Rails.logger.error("[Appointments::InviteReplyHandler] #{@token}: #{e.class}: #{e.message}")
      { success: false, error: e.message }
    end

    private

    # {email:, status:, comment:} from an iTIP REPLY, or nil.
    def calendar_response
      ics = @email[:calendar].to_s
      return nil if ics.blank?

      lines = ics.gsub(/\r?\n[ \t]/, '').split(/\r?\n/)
      return nil unless lines.any? { |l| l.strip.casecmp('METHOD:REPLY').zero? }

      attendee = lines.find { |l| l.start_with?('ATTENDEE') && l =~ /PARTSTAT=/i }
      return nil unless attendee

      comment = lines.find { |l| l.start_with?('COMMENT') }&.split(':', 2)&.last
      {
        email: attendee[/mailto:([^;\s]+)/i, 1].to_s.downcase,
        status: attendee[/PARTSTAT=([A-Z-]+)/i, 1].to_s.downcase,
        comment: unescape(comment)
      }
    end

    def record_response(from, response)
      notices = @activity.customer_notices.to_h
      responses = notices['responses'].to_h
      responses[from] = { 'status' => response[:status], 'at' => Time.current.iso8601, 'comment' => response[:comment] }.compact
      @activity.update_columns(customer_notices: notices.merge('responses' => responses))
    end

    def from_rep?(address)
      return false if address.blank? || @rep.nil?

      [@rep.email, RepMailbox.connection_for(@rep)&.email_address].compact.map(&:downcase).include?(address.downcase)
    end

    def log(response)
      name = @customer.name || @email[:from]
      when_text = TimeText.for(@activity, @customer.company)
      note = [response&.dig(:comment), reply_text].compact_blank.uniq.join("\n\n")
      subject, body =
        if response
          word = STATUS_WORDS[response[:status]] || response[:status].to_s.tr('-', ' ')
          ["#{name} #{word}: #{@activity.subject}",
           "#{name} #{word} the appointment on #{when_text}.#{"\n\nNote: #{note}" if note.present?}"]
        else
          [@email[:subject].presence || "Reply: #{@activity.subject}", note.presence || '(no message)']
        end

      Communication.create!(
        communicable: @customer.record, company_id: @customer.company&.id, channel: 'email', direction: 'inbound',
        from_address: @email[:from], to_address: @email[:to], subject: subject, body: body,
        sent_at: @email[:timestamp] || Time.current, status: 'delivered',
        metadata: { 'source' => 'calendar_reply', 'activity_type' => @activity.class.name, 'activity_id' => @activity.id,
                    'response' => response&.dig(:status), 'message_id' => @email[:message_id] }.compact
      )
    end

    # Canned text calendar clients put on a response, which is not a note.
    CANNED = [
      /\A(accepted|declined|tentative|tentatively accepted|maybe)\b/i,
      /has (accepted|declined|tentatively accepted) this invitation/i,
      /invitation from google calendar/i,
      /you are receiving this (email|courtesy)/i,
      /forwarding this invitation/i,
      /learn more/i,
      /\Areply for /i
    ].freeze

    # What they typed, without the quoted invite under it or the client's
    # canned lines.
    def reply_text
      html = @email[:body_html].presence || @email[:body_text].to_s
      text = ActionController::Base.helpers.strip_tags(InboundEmail::ReplyBodyCleaner.split(html).reply.to_s)
      lines = text.gsub('&nbsp;', ' ').split(/\r?\n/).map { |l| l.gsub(/[ \t]+/, ' ').strip }
      kept = lines.reject { |l| CANNED.any? { |re| l =~ re } }
      kept.join("\n").gsub(/\n{3,}/, "\n\n").strip.presence
    end

    # Who the relay goes to and from where: the assigned rep.
    def rep_outbound
      return nil unless @rep

      Communication.new(from_address: RepMailbox.connection_for(@rep)&.email_address || @rep.email,
                        metadata: { 'sender_user_id' => @rep.id })
    end

    def unescape(text)
      text&.gsub('\\n', "\n")&.gsub(/\\([,;\\])/, '\1')&.strip.presence
    end
  end
end
