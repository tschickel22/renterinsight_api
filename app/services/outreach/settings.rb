# frozen_string_literal: true

module Outreach
  # Proactive Outreach settings for one company (backlog E105), stored in
  # Setting('Company', id, 'proactive_outreach').
  #
  # The module is in no subscription plan. It reaches a company only through a
  # TenantModuleOverride, and it is separate from Quinn AI's own settings so
  # turning it on never starts Quinn texting new leads.
  class Settings
    KEY = 'proactive_outreach'
    MODULE_KEY = 'marketing.proactive_outreach'
    DEMO_MINUTES = [15, 20, 30, 45, 60].freeze
    ACTIONS = %w[reply handoff opt_out].freeze
    MAX_PLAYBOOK = 40

    DEFAULTS = {
      'enabled' => false,
      'persona_name' => '',
      'persona_title' => '',
      'sender_user_id' => nil,
      'demo_minutes' => 30,
      'product_facts' => '',
      'postal_address' => '',
      'playbook' => []
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

    def [](key)
      to_h[key.to_s]
    end

    def add_on?
      ModuleAccessService.new(company).has_module?(MODULE_KEY)
    rescue StandardError
      false
    end

    # Checked again immediately before anything is sent.
    def active?
      add_on? && to_h['enabled'] == true
    end

    def sender
      return nil if to_h['sender_user_id'].blank?

      sender_scope.find_by(id: to_h['sender_user_id'])
    end

    # Who may send: the company's own people, plus anyone whose mailbox is
    # connected for this company. Tom signs in as a platform admin that lives
    # outside DealerTide and sends from a mailbox connected for it.
    def sender_scope
      connected = UserEmailConnection.where(company_id: company.id, is_active: true).select(:user_id)
      User.where(company_id: company.id).or(User.where(id: connected))
    end

    def sender_choices
      people = sender_scope.order(:first_name, :last_name).limit(300).to_a
      mailboxes = UserEmailConnection.where(company_id: company.id, is_active: true, user_id: people.map(&:id)).pluck(:user_id).to_set
      people.map do |person|
        { id: person.id, name: [person.first_name, person.last_name].compact_blank.join(' ').presence || person.email, email: person.email,
          meeting_link: person.meeting_url.present?, mailbox: mailboxes.include?(person.id) }
      end
    end

    def update!(attrs)
      clean = attrs.to_h.stringify_keys.slice(*DEFAULTS.keys)
      clean['enabled'] = ActiveModel::Type::Boolean.new.cast(clean['enabled']) == true if clean.key?('enabled')
      %w[persona_name persona_title].each do |field|
        clean[field] = Assistant::Rules.tidy(clean[field]).truncate(80) if clean.key?(field)
      end
      clean['product_facts'] = clean_block(clean['product_facts']).truncate(8000) if clean.key?('product_facts')
      clean['postal_address'] = Assistant::Rules.tidy(clean['postal_address']).truncate(200) if clean.key?('postal_address')
      clean['sender_user_id'] = sender_scope.find_by(id: clean['sender_user_id'])&.id if clean.key?('sender_user_id')
      if clean.key?('demo_minutes')
        minutes = clean['demo_minutes'].to_i
        clean['demo_minutes'] = DEMO_MINUTES.include?(minutes) ? minutes : DEFAULTS['demo_minutes']
      end
      clean['playbook'] = clean_playbook(clean['playbook']) if clean.key?('playbook')
      Setting.set('Company', company.id, KEY, to_h.merge(clean))
      @to_h = nil
      to_h
    end

    # What is still missing before outreach could run.
    def readiness
      person = sender
      {
        sender: person.present?,
        meeting_link: person&.meeting_url.present?,
        mailbox: person.present? && UserEmailConnection.where(user_id: person.id, company_id: company.id, is_active: true).exists?,
        texting_number: TwilioAccount.active.where(company_id: company.id).exists?,
        approved_content: company.outreach_content_items.approved.exists?,
        playbook: Array(to_h['playbook']).any?,
        product_facts: to_h['product_facts'].present?,
        postal_address: to_h['postal_address'].present?
      }
    end

    private

    # Keeps paragraph breaks, which Assistant::Rules.tidy would flatten.
    def clean_block(text)
      text.to_s.gsub(/\s*[–—]\s*/, ', ').strip
    end

    def clean_playbook(entries)
      Array(entries).filter_map do |entry|
        entry = entry.to_h.stringify_keys
        objection = Assistant::Rules.tidy(entry['objection']).truncate(200)
        answer = clean_block(entry['answer']).truncate(1200)
        next if objection.blank? || answer.blank?

        { 'objection' => objection, 'answer' => answer,
          'action' => ACTIONS.include?(entry['action']) ? entry['action'] : 'reply',
          'share_hint' => Assistant::Rules.tidy(entry['share_hint']).truncate(120) }
      end.first(MAX_PLAYBOOK)
    end
  end
end
