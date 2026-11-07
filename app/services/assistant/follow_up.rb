# frozen_string_literal: true

module Assistant
  # Quinn AI follows up with a buyer who went quiet, until a visit is set
  # (E96, Tom 2026-11-07). Modeled on how Conversica and Impel run it: a
  # series of follow-ups over weeks, each written fresh from what the buyer
  # said, alternating text and email, ending on a polite last check-in.
  #
  # The clock starts when Quinn opens the conversation, and starts over when
  # the buyer writes or a rep hands the conversation back to Quinn. It stops
  # for good when a rep takes over, a visit is booked, the buyer opts out, the
  # lead is marked won or lost, or the plan runs out.
  class FollowUp
    # Days after the clock starts for each follow-up.
    PLANS = {
      'light' => [1, 4, 10],
      'standard' => [1, 3, 7, 14, 21, 30],
      'persistent' => [1, 3, 7, 14, 21, 30, 45, 60, 90]
    }.freeze
    # A lead in one of these is done: no more follow-ups.
    STOP_STATUSES = %w[won lost lost_lead not_a_fit not_qualified junk_lead inactive].freeze
    EMAIL_MAX = 900

    # When the next follow-up is due, or nil when there is none.
    def self.next_due(conversation)
      return nil unless conversation.assistant_answering?
      return nil unless conversation.conversable.is_a?(Lead)
      # A booked visit is what the follow-ups were for.
      return nil if Assistant::Appointments.upcoming_for(conversation.conversable, limit: 1).any?

      settings = Assistant::Settings.for(conversation.company)
      return nil unless conversation.web_chat? ? settings.chat_add_on? : settings.enabled?

      plan = PLANS[settings.cadence]
      return nil if plan.nil? || conversation.follow_up_count >= plan.size

      anchor = conversation.follow_up_anchor_at || conversation.last_inbound_at || conversation.started_at || conversation.created_at
      anchor + plan[conversation.follow_up_count].days
    end

    def self.schedule!(conversation)
      conversation.update_columns(next_follow_up_at: next_due(conversation))
    rescue StandardError => e
      Rails.logger.warn("[Assistant::FollowUp] schedule failed for #{conversation&.id}: #{e.class}: #{e.message}")
    end

    # The clock starts over (the buyer wrote, or a rep handed it back).
    def self.restart!(conversation, at: Time.current)
      conversation.update_columns(follow_up_count: 0, follow_up_anchor_at: at)
      schedule!(conversation)
    end

    def self.run_due
      Conversation.where(status: 'active', assistant_enabled: true).where('next_follow_up_at <= ?', Time.current)
                  .order(:next_follow_up_at).limit(200).each { |c| new(c).run! }
    end

    attr_reader :conversation

    def initialize(conversation)
      @conversation = conversation
      @company = conversation.company
      @lead = conversation.conversable
    end

    def settings
      @settings ||= Assistant::Settings.for(@company)
    end

    def run!
      due = self.class.next_due(conversation)
      return conversation.update_columns(next_follow_up_at: due) if due.nil? || due > 1.minute.from_now
      return stop!('lead closed') if done_with_lead?
      return stop!('visit booked') if Assistant::Appointments.upcoming_for(@lead, limit: 1).any?
      return later!(1.hour) if conversation.visitor_on_page?
      return later!(1.hour) if Assistant::Rules.quiet_now?(settings, conversation.location || @lead.try(:location))

      channel = pick_channel
      return stop!('no way to reach them') unless channel

      sent = channel == :email ? send_email! : send_text!
      conversation.reload
      conversation.update_columns(follow_up_count: conversation.follow_up_count + 1) if sent
      self.class.schedule!(conversation)
      Rails.logger.info("[Assistant::FollowUp] conversation #{conversation.id} follow-up #{conversation.follow_up_count} by #{channel}: #{sent ? 'sent' : 'skipped'}")
    rescue StandardError => e
      Rails.logger.error("[Assistant::FollowUp] conversation #{conversation.id}: #{e.class}: #{e.message}")
      later!(1.day)
    end

    private

    def number
      conversation.follow_up_count + 1
    end

    def plan_size
      PLANS[settings.cadence]&.size.to_i
    end

    def done_with_lead?
      @lead.try(:is_converted) == true || STOP_STATUSES.include?(@lead.try(:status).to_s)
    end

    def stop!(why)
      Rails.logger.info("[Assistant::FollowUp] conversation #{conversation.id} stops: #{why}")
      conversation.update_columns(next_follow_up_at: nil)
    end

    def later!(wait)
      conversation.update_columns(next_follow_up_at: Time.current + wait)
    end

    # Text, email, or nil. "mix" alternates, starting with a text; either
    # setting falls back to the other when the lead allows only one.
    def pick_channel
      text = can_text?
      email = can_email?
      preferred = case settings.follow_up_channels
                  when 'text' then :text
                  when 'email' then :email
                  else number.odd? ? :text : :email
                  end
      return preferred if (preferred == :text && text) || (preferred == :email && email)
      return :email if email
      return :text if text

      nil
    end

    def can_text?
      return false unless settings.enabled? && @lead.phone.present? && @lead.may_text_about_inquiry
      return false if CommunicationOptOut.check(channel: 'sms', company: @company, record: @lead, address: @lead.phone).opted_out?

      conversation.channel == 'sms' || Assistant::Starter.for(@lead).takes_over?
    rescue StandardError
      false
    end

    def can_email?
      return false unless @lead.email.to_s.match?(Assistant::Learn::EMAIL)

      !CommunicationOptOut.check(channel: 'email', company: @company, record: @lead, address: @lead.email).opted_out?
    rescue StandardError
      false
    end

    def draft(channel)
      history = conversation.history(Assistant::Brain::HISTORY)
      follow_up = { number: number, of: plan_size, channel: channel }
      brain = Assistant::Brain.new(conversation: conversation, settings: settings, history: history, follow_up: follow_up,
                                   booking: Assistant::Booking.new(conversation))
      result = brain.call
      body = Assistant::Rules.tidy(result.reply)
      max = channel == :email ? EMAIL_MAX : Assistant::Rules::MAX_LENGTH
      # An email may carry the home links Quinn was given; a text only where
      # the number allows links.
      urls = channel == :email ? brain.home_urls : brain.allowed_urls
      problem = Assistant::Rules.violation(body, allowed_urls: urls, max_length: max)
      if problem
        result = Assistant::Brain.new(conversation: conversation, settings: settings, history: history,
                                      follow_up: follow_up, feedback: problem).call
        body = Assistant::Rules.tidy(result.reply)
        problem = Assistant::Rules.violation(body, allowed_urls: urls, max_length: max)
      end
      return nil if problem

      [body, result]
    end

    def send_text!
      body, result = draft(:text)
      return false unless body

      photos = result.photo_home_id && (v = @company.vehicles.find_by(id: result.photo_home_id)) ? Assistant::Media.photos(v) : []
      meta = { quinn_follow_up: number }
      if conversation.channel == 'sms'
        Assistant::Messenger.deliver!(conversation, body: body, sent_by: 'assistant', media_urls: photos, extra_metadata: meta)
      else
        # A website chat moves to texts: Quinn's text conversation carries
        # the follow-ups from here.
        body = "#{body} Reply STOP to opt out." unless body.match?(/\bSTOP\b/)
        starter = Assistant::Starter.for(@lead)
        starter.send_first_text!(body: body, sent_by: 'assistant', metadata: meta)
        texts = starter.existing || Conversation.open_now.where(conversable: @lead, channel: 'sms').order(:id).last
        if texts
          texts.update_columns(follow_up_count: conversation.follow_up_count + 1, follow_up_anchor_at: conversation.follow_up_anchor_at)
          self.class.schedule!(texts)
        end
        conversation.update_columns(status: 'closed', ended_at: Time.current, handoff_reason: 'moved_to_texts')
        return false
      end
      true
    end

    def send_email!
      body, result = draft(:email)
      return false unless body

      subject = result.subject.to_s.squish.truncate(80).presence || "Your home search with #{@company.name}"
      Assistant::Messenger.email!(conversation, subject: subject, body: body, extra_metadata: { 'quinn_follow_up' => number }, category: 'nurture')
      true
    rescue CommunicationService::OptOutError
      false
    end
  end
end
