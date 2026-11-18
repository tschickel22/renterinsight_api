# frozen_string_literal: true

module Outreach
  # Checks every message in code before it can be sent (backlog E105). The
  # prompt asks for the same things; this is what makes them true.
  module Guard
    TEXT_MAX = 300
    EMAIL_MAX = 900
    URL = %r{https?://|www\.|\b[a-z0-9-]+\.(com|net|org|io|co|us|biz|info|app)\b}i
    PRICE = /\$\s?\d|\b\d+\s?(dollars|bucks)\b|\bper\s+(month|user|seat|location)\b/i
    CLAIMS_HUMAN = /\b(i\s*('m|am)\s+(a\s+)?(real|human|actual)\b|not\s+(a\s+)?(bot|robot|ai|automated)\b|i\s*('m|am)\s+(not|no)\s+(a\s+)?(bot|robot|ai)\b)/i
    MET_THEM = /\b(great|good|nice|pleasure|glad)\s+(meeting|to\s+meet|to\s+have\s+met|seeing|to\s+see)\b|\b(we|i)\s+(met|spoke|talked|chatted)\b|\bstopp(ed|ing)\s+by\b|\bat\s+(my|our|the)\s+booth\b/i
    PLACEHOLDER = /\[[^\]]+\]|\{\{/
    ASKS_IF_AI = /\b(bot|robot|chat\s?gpt)\b|\bare\s+you\s+(an?\s+)?(ai|a\.i\.|real|human|person|automated)\b|\bis\s+this\s+(really\s+)?(tom|you|a\s+person|a\s+human|ai|a\.i\.|automated)\b|\breal\s+person\b/i
    WANTS_OUT = /\b(not\s+interested|no\s+interest|remove\s+me|take\s+me\s+off|unsubscribe|stop\s+(texting|emailing|contacting|messaging)|leave\s+me\s+alone|do\s+not\s+(contact|text|email)|don'?t\s+(contact|text|email))\b/i

    AI_ANSWER = "Fair question. I'm an AI assistant working with %<name>s. %<first>s runs every demo personally. Would you like %<first>s to reach out to you directly?"
    STOP_ANSWER = "Understood. I've taken you off the list and you won't hear from me again."

    module_function

    # nil when the message may be sent; otherwise the reason it may not.
    def violation(text, channel:, lead:)
      body = text.to_s.strip
      return 'the message is empty' if body.empty?
      return 'write it without any web address; a link is added for you' if body.match?(URL)
      return 'never state a price' if body.match?(PRICE)
      return 'never claim to be a person' if body.match?(CLAIMS_HUMAN)
      return 'you have not met this person; do not imply you did' if body.match?(MET_THEM) && !visited_booth?(lead)
      return 'fill in every placeholder' if body.match?(PLACEHOLDER)
      return 'use the name you were given' if body.match?(/\bquinn\b/i)

      max = channel.to_s == 'email' ? EMAIL_MAX : TEXT_MAX
      return "keep it under #{max} characters" if body.length > max

      nil
    end

    def visited_booth?(lead)
      ActiveModel::Type::Boolean.new.cast(lead.custom_field_values.to_h['visited_booth']) == true
    end

    def asks_if_ai?(text)
      text.to_s.match?(ASKS_IF_AI)
    end

    def wants_out?(text)
      text.to_s.match?(WANTS_OUT)
    end

    def ai_answer(settings)
      name = settings['persona_name'].presence || 'the team'
      format(AI_ANSWER, name: name, first: name.split.first)
    end
  end
end
