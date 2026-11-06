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
      'quiet_end_hour' => 8
    }.freeze

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
