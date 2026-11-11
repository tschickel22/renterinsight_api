# frozen_string_literal: true

module Assistant
  # A dealer's Lead Assistant settings (backlog E96), stored per company in
  # Setting('Company', id, 'lead_assistant'). Off until the dealer turns it on,
  # and only for a company that has the marketing.lead_assistant add-on.
  class Settings
    KEY = 'lead_assistant'
    MODULE_KEY = 'marketing.lead_assistant'
    TONES = %w[friendly professional].freeze
    HANDOFF_MODES = %w[owner user].freeze
    # What Quinn works toward, in chat and by text (Tom, 2026-11-07).
    # book_always:      every conversation heads for a visit.
    # book_after_hours: during business hours, the basics and then straight to
    #                   a rep; after hours, heads for a visit.
    # qualify:          learn what they need, then hand to a rep (default).
    # answer_only:      answers questions, asks none, hands off when asked.
    GOALS = %w[book_always book_after_hours qualify answer_only].freeze
    CHAT_MODULE_KEY = 'marketing.ai_concierge'
    # Who texts a new lead when the dealer's plays or nurtures also text them.
    # quinn: Quinn AI does; play and nurture texts to that lead are skipped
    #        while Quinn has (or is about to start) the conversation.
    # plays: plays and nurtures text as built, and Quinn answers the reply.
    TEXTS_FROM = %w[quinn plays].freeze
    # How hard Quinn follows up when a buyer goes quiet (Assistant::FollowUp).
    CADENCES = %w[off light standard persistent].freeze
    FOLLOW_UP_CHANNELS = %w[mix text email].freeze
    MAX_CHAT_SITES = 10

    # The name the assistant goes by when a dealer has not chosen one.
    DEFAULT_NAME = 'Quinn'

    DEFAULTS = {
      'enabled' => false,
      'assistant_name' => DEFAULT_NAME,
      'tone' => 'friendly',
      # 'all', or an array of Source ids the assistant answers leads from.
      'source_ids' => 'all',
      'handoff_mode' => 'owner',
      'handoff_user_id' => nil,
      'extra_facts' => '',
      'quiet_start_hour' => 21,
      'quiet_end_hour' => 8,
      # Answers the dealer added for questions Quinn could not answer:
      # [{ 'q' => ..., 'a' => ... }]. Quinn answers from these like any fact.
      'faqs' => [],
      # The site whose home pages Quinn links to (where links are allowed).
      'link_website_id' => nil,
      # Quinn sends the first text to a new lead from a form, Facebook or the
      # API itself, so it does not depend on a play (Tom, 2026-11-07).
      'auto_start' => true,
      'goal' => 'qualify',
      # Web addresses (host names) of the dealer's own sites that may show the
      # chat through the embed line. Sites we host need no entry.
      'chat_sites' => [],
      'texts_from' => 'quinn',
      'cadence' => 'standard',
      'follow_up_channels' => 'mix',
      # Quinn also reads the FAQs and About text on the dealer's websites
      # (Assistant::Sources). Off when a site still has template copy.
      'use_website_text' => true,
      # The reading of the dealer's own site Quinn uses (SiteContentProfile).
      'site_reading_id' => nil,
      # When a buyer answers by email: answer (Quinn replies by email), draft
      # (Quinn writes it, a rep approves), rep (a person always takes it).
      'email_replies' => 'answer',
      # Hand to a rep when the buyer says they are ready to buy.
      'handoff_on_ready' => true,
      # Hand to a rep when Quinn cannot answer; off, it says it will check
      # and the question waits in the dealer's list.
      'handoff_on_unknown' => true,
      # Hand to a rep after this many buyer messages (0: never).
      'handoff_after' => 0,
      # Quinn books, moves and cancels visits itself (phase 2).
      'books_visits' => true,
      'visit_minutes' => 60,
      # Book every visit with this person instead of the lead's owner (nil:
      # the owner, else the handoff person). DealerTide books its demos with
      # Tom (2026-11-11).
      'book_with_user_id' => nil,
      # in_person, or video: the appointment carries the person's video
      # meeting link (their profile) instead of the dealership's address. nil:
      # video for a software company, in person for everyone else.
      'visit_kind' => nil,
      # How far ahead the earliest time it offers is.
      'booking_notice_hours' => 2,
      # Someone texts the dealer's number without answering anything we sent:
      # new (Quinn answers people not yet in the CRM), leads (also leads with
      # no conversation open), off (a person answers every one).
      'cold_texts' => 'new'
    }.freeze
    EMAIL_REPLIES = %w[answer draft rep].freeze
    VISIT_KINDS = %w[in_person video].freeze
    COLD_TEXTS = %w[new leads off].freeze
    HANDOFF_AFTER = [0, 5, 8, 12].freeze
    MAX_FAQS = 60

    attr_reader :company

    def self.for(company)
      new(company)
    end

    def initialize(company)
      @company = company
    end

    def to_h
      @to_h ||= DEFAULTS.merge((Setting.get('Company', company.id, KEY) || {}).to_h.stringify_keys)
    end

    def update!(attrs)
      clean = attrs.to_h.stringify_keys.slice(*DEFAULTS.keys)
      clean['tone'] = 'friendly' unless TONES.include?(clean.fetch('tone', 'friendly'))
      clean['handoff_mode'] = 'owner' unless HANDOFF_MODES.include?(clean.fetch('handoff_mode', 'owner'))
      if clean.key?('handoff_user_id') && clean['handoff_user_id'].present?
        clean['handoff_user_id'] = company.users.find_by(id: clean['handoff_user_id'])&.id
      end
      if clean.key?('source_ids') && clean['source_ids'] != 'all'
        ids = Array(clean['source_ids']).map(&:to_i)
        clean['source_ids'] = company.sources.where(id: ids).pluck(:id)
      end
      %w[quiet_start_hour quiet_end_hour].each { |k| clean[k] = clean[k].to_i.clamp(0, 23) if clean.key?(k) }
      clean['extra_facts'] = clean['extra_facts'].to_s.truncate(2000) if clean.key?('extra_facts')
      if clean.key?('faqs')
        clean['faqs'] = Array(clean['faqs']).filter_map do |f|
          f = f.to_h.stringify_keys
          q = f['q'].to_s.squish.truncate(300)
          a = f['a'].to_s.squish.truncate(600)
          { 'q' => q, 'a' => a } if q.present? && a.present?
        end.last(MAX_FAQS)
      end
      if clean.key?('book_with_user_id')
        clean['book_with_user_id'] = clean['book_with_user_id'].present? ? company.users.find_by(id: clean['book_with_user_id'])&.id : nil
      end
      clean['visit_kind'] = nil if clean.key?('visit_kind') && !VISIT_KINDS.include?(clean['visit_kind'])
      if clean.key?('link_website_id')
        clean['link_website_id'] = company.websites.find_by(id: clean['link_website_id'])&.id
      end
      clean['goal'] = 'qualify' if clean.key?('goal') && !GOALS.include?(clean['goal'])
      clean['texts_from'] = 'quinn' if clean.key?('texts_from') && !TEXTS_FROM.include?(clean['texts_from'])
      clean['cadence'] = 'standard' if clean.key?('cadence') && !CADENCES.include?(clean['cadence'])
      clean['follow_up_channels'] = 'mix' if clean.key?('follow_up_channels') && !FOLLOW_UP_CHANNELS.include?(clean['follow_up_channels'])
      clean['auto_start'] = ActiveModel::Type::Boolean.new.cast(clean['auto_start']) == true if clean.key?('auto_start')
      clean['use_website_text'] = ActiveModel::Type::Boolean.new.cast(clean['use_website_text']) == true if clean.key?('use_website_text')
      clean['visit_minutes'] = [30, 45, 60, 90, 120].include?(clean['visit_minutes'].to_i) ? clean['visit_minutes'].to_i : 60 if clean.key?('visit_minutes')
      clean['booking_notice_hours'] = clean['booking_notice_hours'].to_i.clamp(0, 72) if clean.key?('booking_notice_hours')
      %w[handoff_on_ready handoff_on_unknown books_visits].each do |k|
        clean[k] = ActiveModel::Type::Boolean.new.cast(clean[k]) == true if clean.key?(k)
      end
      clean['email_replies'] = 'answer' if clean.key?('email_replies') && !EMAIL_REPLIES.include?(clean['email_replies'])
      clean['cold_texts'] = 'new' if clean.key?('cold_texts') && !COLD_TEXTS.include?(clean['cold_texts'])
      clean['handoff_after'] = HANDOFF_AFTER.include?(clean['handoff_after'].to_i) ? clean['handoff_after'].to_i : 0 if clean.key?('handoff_after')
      clean['chat_sites'] = self.class.clean_sites(clean['chat_sites']) if clean.key?('chat_sites')
      clean['assistant_name'] = clean['assistant_name'].to_s.strip.truncate(40).presence || DEFAULT_NAME if clean.key?('assistant_name')
      Setting.set('Company', company.id, KEY, to_h.merge(clean))
      @to_h = nil
      to_h
    end

    def add_on?
      ModuleAccessService.new(company).has_module?(MODULE_KEY)
    rescue StandardError
      false
    end

    def enabled?
      to_h['enabled'] == true && add_on?
    end

    # The website chat add-on. The chat answers as Quinn with these same
    # settings, whether or not the dealer also has Quinn by text.
    def chat_add_on?
      ModuleAccessService.new(company).module_enabled?(CHAT_MODULE_KEY)
    rescue StandardError
      false
    end

    def auto_start?
      enabled? && to_h['auto_start'] != false
    end

    def goal
      GOALS.include?(to_h['goal']) ? to_h['goal'] : 'qualify'
    end

    def chat_sites
      Array(to_h['chat_sites'])
    end

    def books_visits?
      to_h['books_visits'] != false
    end

    def visit_minutes
      (to_h['visit_minutes'].presence || 60).to_i
    end

    def book_with_user
      id = to_h['book_with_user_id']
      user = id.present? ? company.users.find_by(id: id) : nil
      user&.active? ? user : nil
    end

    def video_visits?
      kind = to_h['visit_kind']
      VISIT_KINDS.include?(kind) ? kind == 'video' : Assistant::Software.for?(company)
    end

    def booking_notice_hours
      (to_h['booking_notice_hours'].presence || 2).to_i
    end

    def email_replies
      EMAIL_REPLIES.include?(to_h['email_replies']) ? to_h['email_replies'] : 'answer'
    end

    def handoff_after
      to_h['handoff_after'].to_i
    end

    def cold_texts
      COLD_TEXTS.include?(to_h['cold_texts']) ? to_h['cold_texts'] : 'new'
    end

    def quinn_leads_texting?
      to_h['texts_from'] != 'plays'
    end

    def cadence
      CADENCES.include?(to_h['cadence']) ? to_h['cadence'] : 'standard'
    end

    def follow_up_channels
      FOLLOW_UP_CHANNELS.include?(to_h['follow_up_channels']) ? to_h['follow_up_channels'] : 'mix'
    end

    # Whether a page on this host may show the embedded chat. "www." is
    # ignored, and a listed host covers its own subdomains.
    def chat_site_allowed?(host)
      host = self.class.normalize_host(host)
      return false if host.blank?

      chat_sites.any? { |site| host == site || host.end_with?(".#{site}") }
    end

    def self.normalize_host(value)
      text = value.to_s.strip.downcase
      return nil if text.blank?

      text = "https://#{text}" unless text.match?(%r{\Ahttps?://})
      URI.parse(text).host.to_s.sub(/\Awww\./, '').presence
    rescue URI::InvalidURIError
      nil
    end

    def self.clean_sites(list)
      Array(list).filter_map { |v| normalize_host(v) }.uniq.first(MAX_CHAT_SITES)
    end

    def answers_source?(source_id)
      ids = to_h['source_ids']
      return true if ids == 'all' || ids.nil?

      Array(ids).map(&:to_i).include?(source_id.to_i)
    end

    def assistant_name
      to_h['assistant_name'].presence || DEFAULT_NAME
    end

    def [](key)
      to_h[key.to_s]
    end
  end
end
