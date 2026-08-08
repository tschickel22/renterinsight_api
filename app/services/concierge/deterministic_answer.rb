# frozen_string_literal: true

module Concierge
  # Answers the questions that do not need a model.
  #
  # Most of what a visitor asks a dealer's chat is one of about eight things:
  # where are you, when are you open, what is your number, do you finance, do you
  # deliver, can I book a visit, what have you got, how much. Every one of those
  # is a fact we already hold, and spending a model call on them is spending
  # money to be slower and less reliable at reading our own database.
  #
  # Returns nil when nothing matches, which is the signal to escalate. That is
  # the whole design: the model is the fallback, not the front door.
  class DeterministicAnswer
    PATTERNS = {
      hours: /\b(hours?|open|close|closing|opening|what time|when.*(open|close))\b/i,
      location: /\b(where|address|located|location|directions|find you|come see)\b/i,
      phone: /\b(phone|call|number|contact you|reach you|talk to someone)\b/i,
      financing: /\b(financ|loan|credit|payment plan|mortgage|lender|apply|approv|down payment|interest|rate|apr|qualify|afford)\b/i,
      delivery: /\b(deliver|install|set ?up|transport|haul|move it|foundation)\b/i,
      booking: /\b(appointment|book|schedule|tour|visit|come by|walk through|see it in person|meet)\b/i,
      greeting: /\A\s*(hi|hey|hello|good (morning|afternoon|evening))\b[\s!.,]*\z/i
    }.freeze

    def initialize(text:, knowledge:, booking_url: nil, lead_form_path: nil)
      @text = text.to_s
      @k = knowledge
      @booking_url = booking_url
      @lead_form_path = lead_form_path
    end

    # @return [Hash, nil] { text:, actions: [] } or nil to escalate
    def call
      intent = PATTERNS.find { |_, pattern| @text.match?(pattern) }&.first
      return nil if intent.nil?

      send("answer_#{intent}")
    end

    private

    def facts
      @facts ||= @k.to_h
    end

    def book_action
      # A booking link when the dealer has one, the enquiry form when they do
      # not. Never nothing: the point of recognising the intent is to act on it.
      return { type: 'link', label: 'Book a time', url: @booking_url } if @booking_url.present?

      { type: 'form', label: 'Request a callback', path: @lead_form_path || '/contact' }
    end

    def answer_greeting
      { text: "Hi. I can help you find a home, answer questions about #{facts[:dealer_name]}, " \
              'or get a visit booked. What are you after?',
        actions: [book_action] }
    end

    # When a fact is missing, say so from here rather than escalating. Paying a
    # model call to discover we do not know our own opening hours is the exact
    # spend this tier exists to avoid, and the honest answer is the same either
    # way.
    def answer_hours
      return { text: "I don't have our hours listed here. The team can confirm them.",
               actions: [book_action] } if facts[:hours].blank?

      { text: "Our hours are #{facts[:hours]}.", actions: [book_action] }
    end

    def answer_location
      return { text: "I don't have our address listed here, but the team can point you to us.",
               actions: [book_action] } if facts[:address].blank?

      { text: "We're at #{facts[:address]}.",
        actions: [{ type: 'link', label: 'Get directions',
                    url: "https://maps.google.com/?q=#{CGI.escape(facts[:address])}" }, book_action] }
    end

    def answer_phone
      return { text: 'I do not have a number listed here. Leave your details and someone will ' \
                     'call you straight back.',
               actions: [{ type: 'form', label: 'Request a callback', path: @lead_form_path || '/contact' }] } if facts[:phone].blank?

      { text: "You can reach us on #{facts[:phone]}.",
        actions: [{ type: 'link', label: 'Call now', url: "tel:#{facts[:phone].gsub(/[^\d+]/, '')}" }] }
    end

    # Deliberately vague on terms and deliberately so. Quoting a rate or a
    # approval likelihood is the fastest way for a chat widget to create a
    # promise the dealer has to honour, and in several states to create a
    # compliance problem.
    def answer_financing
      { text: 'We work with several lenders and can walk you through the options, including ' \
              'land-home packages. The quickest way is to send your details and a member of the ' \
              'team will talk you through what you would qualify for.',
        actions: [{ type: 'form', label: 'Start a finance chat', path: @lead_form_path || '/contact' },
                  book_action] }
    end

    def answer_delivery
      { text: 'Yes. We handle delivery, set up and the utility connections, and can talk you ' \
              'through what your site needs.',
        actions: [book_action] }
    end

    def answer_booking
      { text: 'Happy to get that booked.', actions: [book_action] }
    end
  end
end
