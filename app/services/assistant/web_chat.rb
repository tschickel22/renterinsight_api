# frozen_string_literal: true

module Assistant
  # The website chat, answered by Quinn and kept in the Inbox (E96, 2026-11-07).
  #
  # Each visitor chat is a Conversation with channel web_chat, found by a
  # random key the server hands the visitor's browser on their first message.
  # Quinn answers straight away (a person on a web page waits seconds, not the
  # 20 to 45 a text gets), with the same brain, goal, rules, handoff and "what
  # Quinn learned" as texts. Once a person has it, Quinn stays quiet and the
  # rep answers from the Inbox; the widget picks up their messages by asking
  # every few seconds.
  #
  # A lead is made from the chat once the visitor gives a name and an email
  # (through the dealer's own form, Concierge::LeadCapture), or a mobile number
  # with the texting consent the widget asks for (ConciergeController#lead).
  class WebChat
    MAX_TEXT = 500
    MAX_REPLY = 700
    KEY = /\A[A-Za-z0-9_-]{20,64}\z/

    Reply = Struct.new(:messages, :ask_consent, :visitor, :usage, :events, keyword_init: true)

    def self.find(company, key)
      return nil if company.nil? || !key.to_s.match?(KEY)

      company.conversations.find_by(channel: 'web_chat', visitor_token: key.to_s)
    end

    def self.start!(company:, website: nil, lead: nil, page_url: nil)
      company.conversations.create!(
        channel: 'web_chat', status: 'active', assistant_enabled: true,
        visitor_token: SecureRandom.urlsafe_base64(24), website_id: website&.id,
        location_id: lead&.location_id || website.try(:location_id),
        conversable: lead, assigned_user_id: lead.try(:owner_id),
        chat_page_url: page_url.to_s.truncate(500).presence, started_at: Time.current, visitor_seen_at: Time.current
      )
    end

    # Opens a chat for a lead who just sent the dealer's form, so they can keep
    # talking while they are on the page. Quinn's first message greets them by
    # name; no model call.
    def self.after_form!(lead:, website: nil, page_url: nil)
      settings = Assistant::Settings.for(lead.company)
      conversation = start!(company: lead.company, website: website, lead: lead, page_url: page_url)
      first = lead.try(:first_name).to_s.strip
      first = '' if first.match?(Assistant::Learn::PLACEHOLDER_NAME)
      about = Assistant::Software.for?(lead.company) ? "#{lead.company.name} or a demo" : 'the homes or a visit'
      greeting = "Thanks#{", #{first}" if first.present?}! I'm #{settings.assistant_name} with #{lead.company.name}. " \
                 "While you are here, is there anything I can answer about #{about}?"
      Assistant::Messenger.deliver!(conversation, body: greeting, sent_by: 'assistant')
      conversation
    end

    attr_reader :conversation

    def initialize(conversation, website: nil, request_context: {})
      @conversation = conversation
      @company = conversation.company
      @website = website
      @request_context = request_context || {}
    end

    def seen!
      conversation.update_columns(visitor_seen_at: Time.current)
    end

    # The visitor sent a message. Returns what to show them now.
    def visitor_says!(text)
      text = text.to_s.strip.truncate(MAX_TEXT)
      return Reply.new(messages: []) if text.blank?

      message = conversation.chat_messages.create!(company_id: @company.id, direction: 'inbound', sent_by: 'visitor', body: text)
      conversation.note_message!(message)
      seen!
      return Reply.new(messages: []) unless conversation.assistant_answering?

      before = conversation.chat_messages.maximum(:id)
      reply = answer!(text)
      reply.messages = conversation.chat_messages.where('id > ?', before).order(:id).map(&:as_chat_json)
      reply
    end

    private

    def settings
      @settings ||= Assistant::Settings.for(@company)
    end

    def answer!(text)
      # A home search ("3 bed under 80k") is a database query, shown as cards:
      # no model, and no chance of a home that does not exist.
      # Quinn always answers (a message can carry a search, a name and a
      # request at once). A specific search ("3 bed under 80k") also shows the
      # matching homes as cards under its reply, straight from the stock the
      # site serves.
      return brain_answer!([]) if Assistant::Software.for?(@company)

      filters = Concierge::InventoryQuery.new(text).call
      matches = filters.present? ? Concierge::InventorySearch.new(company: @company, filters: filters).call.map { |l| absolute(l) } : []
      brain_answer!(matches)
    end

    # Quinn asks for this when a visitor wants a person before giving any way
    # to reach them.
    ASK_CONTACT = 'So someone from the team can follow up, what is your name and a good email or mobile number?'

    def brain_answer!(matches = [])
      # A handoff waiting for the visitor's name and contact (see hold_handoff!).
      held = conversation.handoff_reason.presence if conversation.conversable.blank?
      history = conversation.history(Assistant::Brain::HISTORY)
      showing = matches.map { |m| m[:name] }
      # A visitor with a lead can book in the chat (phase 2).
      booking = conversation.conversable ? Assistant::Booking.new(conversation) : nil
      brain = Assistant::Brain.new(conversation: conversation, settings: settings, history: history, showing: showing, booking: booking)
      result = brain.call
      Assistant::Learn.apply!(conversation, result)

      reply = Assistant::Rules.tidy(result.reply)
      problem = Assistant::Rules.violation(reply, allowed_urls: brain.allowed_urls, max_length: MAX_REPLY)
      if problem && !result.handoff
        result = Assistant::Brain.new(conversation: conversation, settings: settings, history: history, feedback: problem, showing: showing,
                                      booking: booking).call
        Assistant::Learn.apply!(conversation, result)
        reply = Assistant::Rules.tidy(result.reply)
        problem = Assistant::Rules.violation(reply, allowed_urls: brain.allowed_urls, max_length: MAX_REPLY)
      end
      reason = result.handoff ? result.handoff_reason : nil

      events = []
      if !problem && booking && (outcome = booking.apply(result))
        events << Assistant::Conversions.schedule(outcome.activity) if outcome.ok && outcome.kind == 'booked'
        if outcome.ok
          reply = Assistant::Booking.combine(reply, outcome)
          reason = nil if %w[appointment visit_time].include?(reason)
        elsif outcome.text.present?
          reply = outcome.text
        else
          reason ||= 'appointment'
        end
      end

      events << Assistant::Conversions.lead(lead_from_chat!(result.contact))
      Assistant::Booking.note_details!(conversation) if result.qualification.present?
      if conversation.conversable.blank?
        # Nobody can follow up with a visitor we cannot reach, and a lead needs
        # a name and an email or phone (Tom, 2026-11-12). Quinn keeps the chat,
        # asks for them, and hands off once the lead is made.
        if problem || reason
          hold_handoff!(reason || 'rule_check')
          reply = problem || reply.blank? ? ASK_CONTACT : with_contact_ask(reply)
          problem = nil
          reason = nil
        end
      elsif held && conversation.assistant_answering?
        # This message made the lead: the waiting handoff goes ahead now.
        reason ||= held
      end
      Assistant::Learn.record_question(conversation, result, reason, problem)
      listings = (home_card(result.photo_home_id) + matches).uniq { |l| l[:id] }.first(4)
      # A training video that shows what they asked about (software company).
      # Once per chat: Quinn tends to set the same video again on the next reply.
      actions = result.video && !video_shown?(result.video) ? [Assistant::Software.video_action(result.video)] : []

      if problem
        Assistant::Handoff.perform!(conversation, reason: reason || 'rule_check', summary: result.summary)
      elsif reason
        Assistant::Messenger.deliver!(conversation, body: reply, extra_metadata: { listings: listings, actions: actions }) if reply.present?
        Assistant::Handoff.perform!(conversation, reason: reason, summary: result.summary, buyer_text: reply.present? ? nil : :default)
      else
        Assistant::Messenger.deliver!(conversation, body: reply, extra_metadata: { listings: listings, actions: actions })
      end

      Reply.new(messages: [], ask_consent: ask_consent?(result.contact), visitor: visitor_details(result.contact),
                usage: result.usage, events: events.compact)
    rescue StandardError => e
      Rails.logger.error("[Assistant::WebChat] conversation #{conversation.id}: #{e.class}: #{e.message}")
      # Never silence in front of a buyer: a person takes it.
      Assistant::Handoff.perform!(conversation, reason: 'error', summary: nil) if conversation.reload.assistant_answering?
      Reply.new(messages: [])
    end

    # Kept on the conversation while it stays active, so the Inbox still shows
    # it as Quinn's. hand_back! and taken_over! replace it.
    def hold_handoff!(reason)
      conversation.update!(handoff_reason: reason)
    end

    def with_contact_ask(reply)
      return reply if reply.match?(/\bname\b/i) && reply.match?(/e-?mail|phone|number/i)

      "#{reply} #{ASK_CONTACT}"
    end

    def video_shown?(video)
      page = video[:url].to_s.split('?').first
      conversation.chat_messages.where(direction: 'outbound').where.not(actions: [nil, []]).any? do |m|
        Array(m.actions).any? { |a| a.to_h['url'].to_s.split('?').first == page }
      end
    end

    # The visitor gave a name and an email: make the lead through the dealer's
    # own form, so it arrives like any other website lead. Returns the lead
    # when this message made it (for the page's ad pixel), else nil.
    def lead_from_chat!(contact)
      return if conversation.conversable.present? || contact.blank?

      name = [contact['first_name'], contact['last_name']].compact_blank.join(' ')
      email = contact['email'].to_s.downcase
      return if name.blank? || !email.match?(Assistant::Learn::EMAIL)

      capture = Concierge::LeadCapture.new(company: @company, website: @website)
      # The phone too, for calls; texting it waits for the chat's consent.
      result = capture.call(visitor: { name: name, email: email, phone: contact['phone'].to_s.strip.presence }.compact,
                            intent: 'contact', transcript: transcript,
                            consented: false, request_context: @request_context)
      lead = @company.leads.find_by(id: result.lead_id) if result.status == 'created'
      # brain_answer! hands off any held handoff itself, with Quinn's reply.
      self.class.link!(conversation, lead, release_held: false) if lead
      lead
    end

    # A conversation and the lead made from it, one record from then on.
    # A handoff Quinn held for want of a way to reach the visitor goes to the
    # lead's owner (the form's rotation) now that there is one.
    def self.link!(conversation, lead, release_held: true)
      return unless lead

      conversation.update!(conversable: lead, assigned_user_id: conversation.assigned_user_id || lead.try(:owner_id),
                           location_id: conversation.location_id || lead.location_id)
      Assistant::Learn.copy_fields(lead, conversation.qualification)
      Assistant::CrmFields.note!(conversation) if Assistant::Software.for?(conversation.company)
      held = conversation.handoff_reason.presence
      Assistant::Handoff.perform!(conversation, reason: held) if release_held && held && conversation.assistant_answering?
    end

    def transcript
      conversation.chat_messages.order(:id).last(12).map do |m|
        { 'role' => m.direction == 'inbound' ? 'user' : 'assistant', 'content' => m.body }
      end
    end

    # A mobile number typed in the chat is used for texts only after the
    # visitor says yes to the consent line the widget shows.
    def ask_consent?(contact)
      phone = contact.to_h['phone'].to_s.gsub(/\D/, '')
      return false if phone.length < 10

      lead = conversation.conversable
      !(lead.is_a?(Lead) && lead.phone.present? && lead.may_text_about_inquiry)
    end

    def visitor_details(contact)
      contact = contact.to_h
      { name: [contact['first_name'], contact['last_name']].compact_blank.join(' ').presence,
        email: contact['email'].presence, phone: contact['phone'].presence }.compact
    end

    def home_card(vehicle_id)
      return [] unless vehicle_id

      vehicle = @company.vehicles.find_by(id: vehicle_id)
      return [] unless vehicle

      [absolute(id: vehicle.id, name: [vehicle.year, vehicle.make, vehicle.model].compact_blank.join(' '),
                price: vehicle.sale_price&.to_i, bedrooms: vehicle.bedrooms, bathrooms: vehicle.bathrooms,
                square_feet: vehicle.square_feet, image: vehicle.public_image_urls.first,
                path: Websites::HomeUrl.path_for(vehicle))]
    rescue StandardError
      []
    end

    # On a site we host a home's path is a page of that site. In the embedded
    # chat on the dealer's own site it is not, so the card carries the full
    # address of the home on the dealer's published site.
    def absolute(listing)
      listing = listing.to_h.symbolize_keys
      return listing if @website || listing[:path].blank?

      base = Assistant::Media.published_site_url(@company)
      base ? listing.merge(url: "#{base.chomp('/')}#{listing[:path]}") : listing
    rescue StandardError
      listing
    end
  end
end
