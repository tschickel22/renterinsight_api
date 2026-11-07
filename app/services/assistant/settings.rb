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
      'follow_up_channels' => 'mix'
    }.freeze
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
      if clean.key?('link_website_id')
        clean['link_website_id'] = company.websites.find_by(id: clean['link_website_id'])&.id
      end
      clean['goal'] = 'qualify' if clean.key?('goal') && !GOALS.include?(clean['goal'])
      clean['texts_from'] = 'quinn' if clean.key?('texts_from') && !TEXTS_FROM.include?(clean['texts_from'])
      clean['cadence'] = 'standard' if clean.key?('cadence') && !CADENCES.include?(clean['cadence'])
      clean['follow_up_channels'] = 'mix' if clean.key?('follow_up_channels') && !FOLLOW_UP_CHANNELS.include?(clean['follow_up_channels'])
      clean['auto_start'] = ActiveModel::Type::Boolean.new.cast(clean['auto_start']) == true if clean.key?('auto_start')
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
