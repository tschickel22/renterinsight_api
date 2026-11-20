# frozen_string_literal: true

module Outreach
  # Checks every message in code before it can be sent (backlog E105). The
  # prompt asks for the same things; this is what makes them true.
  module Guard
    TEXT_MAX = 300
    # Body of an opener or follow-up text. With the short video link and the
    # opt out line it stays within two segments (research, 2026-11-20).
    FIRST_TEXT_MAX = 200
    EMAIL_MAX = 900
    URL = %r{https?://|www\.|\b[a-z0-9-]+\.(com|net|org|io|co|us|biz|info|app)\b}i
    PRICE = /\$\s?\d|\b\d+\s?(dollars|bucks)\b|\bper\s+(month|user|seat|location)\b/i
    CLAIMS_HUMAN = /\b(i\s*('m|am)\s+(a\s+)?(real|human|actual)\b|not\s+(a\s+)?(bot|robot|ai|automated)\b|i\s*('m|am)\s+(not|no)\s+(a\s+)?(bot|robot|ai)\b)/i
    MET_THEM = /\b(great|good|nice|pleasure|glad)\s+(meeting|to\s+meet|to\s+have\s+met|seeing|to\s+see)\b|\b(we|i)\s+(met|spoke|talked|chatted)\b|\bstopp(ed|ing)\s+by\b|\bat\s+(my|our|the)\s+booth\b/i
    PLACEHOLDER = /\[[^\]]+\]|\{\{/
    # Phrases that make a message read as machine written (research 2026-11-20).
    AI_TELLS = Regexp.new("\\b(" + %w[
      hope\s+(this|you're|youre|all\s+is)[^.]{0,20}well
      i\s+came\s+across
      i\s+wanted\s+to\s+reach\s+out
      quick\s+question
      just\s+checking\s+in
      touching\s+base
      circling\s+back
      following\s+up\s+on\s+my
      bumping\s+this
      i'?d\s+love\s+to
      don'?t\s+hesitate
      game[\s-]?changer
      streamline
      leverag(e|ing)
      elevate
      empower
      unlock
      seamless(ly)?
      robust
      revolutioni[sz]e
      cutting[\s-]edge
      delve
      comprehensive
      utili[sz]e
      furthermore
      moreover
      in\s+today'?s\s+fast
    ].join('|') + ')\\b', Regexp::IGNORECASE)
    # The first production wave told people which list they were on.
    WHERE_FROM = /\b(on|from|through|via|in)\s+(our|the|a|your)\s+[\w\s']{0,30}\b(list|database|records)\b|\byour (info|information|details|contact)\b/i
    ASKS_IF_AI = /\b(bot|robot|chat\s?gpt)\b|\bare\s+you\s+(an?\s+)?(ai|a\.i\.|real|human|person|automated)\b|\bis\s+this\s+(really\s+)?(tom|you|a\s+person|a\s+human|ai|a\.i\.|automated)\b|\breal\s+person\b/i
    WANTS_OUT = /\b(not\s+interested|no\s+interest|remove\s+me|take\s+me\s+off|unsubscribe|stop\s+(texting|emailing|contacting|messaging)|leave\s+me\s+alone|do\s+not\s+(contact|text|email)|don'?t\s+(contact|text|email))\b/i

    AI_ANSWER = "Fair question. I'm an AI assistant working with %<name>s. %<first>s runs every demo personally. Would you like %<first>s to reach out to you directly?"
    STOP_ANSWER = "Understood. I've taken you off the list and you won't hear from me again."

    module_function

    # nil when the message may be sent; otherwise the reason it may not.
    # style: false skips the wording checks, for a message the sender wrote or
    # edited by hand (they may use an exclamation mark if they like).
    # where_from: false in a reply, where they may have asked how we got their number.
    # text_max: openers and follow-ups by text are held shorter than replies.
    def violation(text, channel:, lead:, style: true, where_from: true, text_max: TEXT_MAX)
      body = text.to_s.strip
      return 'the message is empty' if body.empty?
      return 'write it without any web address; a link is added for you' if body.match?(URL)
      return 'never state a price' if body.match?(PRICE)
      return 'never claim to be a person' if body.match?(CLAIMS_HUMAN)
      return 'you have not met this person; do not imply you did' if body.match?(MET_THEM) && !visited_booth?(lead)
      return 'fill in every placeholder' if body.match?(PLACEHOLDER)
      return 'use the name you were given' if body.match?(/\bquinn\b/i)
      return 'never say how you got their details or name a list' if where_from && (body.match?(WHERE_FROM) || names_source?(body, lead))
      if style
        tell = body[AI_TELLS]
        return "it reads as machine written; do not use \"#{tell}\"" if tell
        return 'do not use exclamation marks' if body.include?('!')
      end

      max = channel.to_s == 'email' ? EMAIL_MAX : text_max
      return "keep it under #{max} characters" if body.length > max

      nil
    end

    # Email subjects: the same wording and source rules, kept short.
    def subject_violation(subject, lead:, company:)
      text = subject.to_s.strip
      return 'write a subject' if text.empty?
      return "the subject reads as machine written; do not use \"#{text[AI_TELLS]}\"" if text.match?(AI_TELLS)
      return 'the subject must not name a list or where their details came from' if text.match?(WHERE_FROM) || names_source?(text, lead)
      return 'keep the subject to a few plain words without our company name' if text.split.size > 7 || text.downcase.include?(company.name.to_s.split.first.to_s.downcase)

      nil
    end

    # The lead's source (a show or list name) may be said only to booth visitors.
    def names_source?(body, lead)
      name = lead.source&.name.to_s.strip
      name.length >= 4 && !visited_booth?(lead) && body.downcase.include?(name.downcase)
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
