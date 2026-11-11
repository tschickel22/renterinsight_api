# frozen_string_literal: true

module Assistant
  # Opens a Lead Assistant conversation with the first text a play sends a new
  # lead (backlog E96). The dealer's own words still go out; from then on the
  # buyer's replies are answered by the assistant.
  class Starter
    # Leads from a partner that runs its own AI on the buyer (Mobile Home Guys
    # through GoHighLevel, E95). Two bots on one buyer is the worst outcome.
    PARTNER_AI_SOURCE = /mobile\s*home\s*guys|gohighlevel|\bmhg\b/i

    attr_reader :lead

    def self.for(entity)
      new(entity)
    end

    def initialize(lead)
      @lead = lead
    end

    def existing
      @existing ||= Assistant::Threading.open_conversation_for(lead, lead.try(:phone))
    end

    def takes_over?
      existing.present? || (eligible? && sender.present?)
    end

    # What a play's or nurture's text to this lead should do (E96):
    #   :normal   send it as built (Quinn is not involved)
    #   :skip     do not send: Quinn AI has, or is about to start, this
    #             conversation and the dealer chose "Quinn AI leads"
    #   :quinn    send it into Quinn's conversation, so Quinn answers the reply
    # to: the number the step texts. A text to anyone but the lead (a staff
    # alert to the owner) is never routed into the buyer's conversation.
    def automation_route(to)
      return :normal unless lead.is_a?(Lead) && lead.phone.present?
      return :normal unless Conversation.normalize_phone(to) == Conversation.normalize_phone(lead.phone)

      settings = Assistant::Settings.for(lead.company)
      return :normal unless settings.enabled?

      if existing
        settings.quinn_leads_texting? ? :skip : :quinn
      elsif eligible? && sender
        settings.quinn_leads_texting? && will_start? ? :skip : :quinn
      else
        :normal
      end
    rescue StandardError => e
      Rails.logger.error("[Assistant::Starter] route failed for lead #{lead.try(:id)}: #{e.class}: #{e.message}")
      :normal
    end

    # Quinn's own first text is coming (AssistantStartJob would send it).
    def will_start?
      Assistant::Settings.for(lead.company).auto_start? &&
        AssistantStartJob::ORIGINS.include?(lead.origin.to_s) && lead.created_at > AssistantStartJob::FRESH_FOR.ago
    end

    def eligible?
      return false unless lead.is_a?(Lead) && lead.phone.present? && lead.may_text_about_inquiry
      return false if lead.source&.name.to_s.match?(PARTNER_AI_SOURCE)

      settings = Assistant::Settings.for(lead.company)
      return false unless settings.enabled? && settings.answers_source?(lead.source_id)

      !CommunicationOptOut.check(channel: 'sms', company: lead.company, record: lead, address: lead.phone).opted_out?
    end

    # The dealer's own live number, else a free pool number, else nil.
    def sender
      @sender ||= own_number || pool_number
    end

    # sent_by: 'play' for a play's own words, 'assistant' when Quinn writes the
    # first text itself (AssistantStartJob).
    def send_first_text!(body:, metadata: {}, sent_by: 'play')
      conversation = existing || open!
      body = identify(body, conversation)
      Assistant::Messenger.deliver!(conversation, body: body, sent_by: sent_by, extra_metadata: metadata)
    end

    def open!
      s = sender
      raise ArgumentError, 'no number to text from' unless s

      Conversation.create!(
        company_id: lead.company_id, location_id: lead.location_id, conversable: lead, channel: 'sms',
        assigned_user_id: lead.try(:owner_id), sender_number: s[:number], buyer_phone: lead.phone,
        pool: s[:pool], messaging_service_sid: s[:messaging_service_sid], status: 'active', started_at: Time.current
      )
    end

    private

    def own_number
      accounts = TwilioAccount.active.where(company_id: lead.company_id)
      account = accounts.find_by(location_id: lead.location_id) if lead.location_id
      account ||= accounts.find_by(location_id: nil) || accounts.first
      account && { number: Conversation.normalize_phone(account.phone_number), pool: false, messaging_service_sid: nil }
    end

    def pool_number
      return nil unless Assistant::Pool.available_for?(lead.company)

      entry = Assistant::Pool.pick_for(lead.phone)
      entry && entry.merge(pool: true)
    end

    # The first text names the dealer, whatever the template says.
    def identify(body, conversation)
      return body if conversation.pool? # the pool prefix names the dealer
      name = Assistant::Messenger.dealer_name(conversation)
      body.to_s.downcase.include?(name.downcase) ? body : "#{name}: #{body}"
    end
  end
end
