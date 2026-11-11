# frozen_string_literal: true

module Assistant
  # The shared texting numbers a dealer's assistant uses until the dealer's own
  # number is live (backlog E96, phase 3). Platform setting 'assistant_pool':
  #
  #   { "live" => true,
  #     "numbers" => [{ "number" => "+19704632673", "messaging_service_sid" => "MG..." }],
  #     "companies" => [{ "id" => 24, "added_at" => "2026-11-11T21:30:00Z" }] }
  #
  # A dealer texts from the pool only once a platform admin has added them
  # (Platform Admin, Texting registrations, Shared numbers). Live alone sends
  # nothing: every dealer is off the pool until someone decides otherwise.
  #
  # Each environment holds its own numbers on its own Messaging Service and A2P
  # campaign. Nothing is sent from the pool until "live" is true, which is set by
  # hand once the campaign is VERIFIED and a test text has arrived on a T-Mobile
  # handset (CLAUDE.md, A2P 10DLC delivery).
  module Pool
    KEY = 'assistant_pool'

    module_function

    def config
      (Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, KEY) || {}).to_h.deep_stringify_keys
    end

    def live?
      config['live'] == true && entries.any?
    end

    def entries
      Array(config['numbers']).filter_map do |e|
        number = Conversation.normalize_phone(e['number'])
        number && { number: number, messaging_service_sid: e['messaging_service_sid'].presence }
      end
    end

    def company_entries
      Array(config['companies']).filter_map do |c|
        id = c.is_a?(Hash) ? c['id'].to_i : c.to_i
        id.positive? ? { id: id, added_at: (c['added_at'] if c.is_a?(Hash)) } : nil
      end
    end

    def company_ids
      company_entries.map { |c| c[:id] }
    end

    def company_allowed?(company)
      company.present? && company_ids.include?(company.id)
    end

    # Everything that must hold before a dealer's assistant may start a new
    # conversation on a shared number.
    def available_for?(company)
      live? && company_allowed?(company)
    end

    def first_pool_text_at(company)
      Conversation.where(company_id: company.id, pool: true).minimum(:started_at)
    end

    def update!(attrs)
      Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, KEY, config.merge(attrs.deep_stringify_keys))
    end

    def add_company!(company)
      return if company_allowed?(company)

      list = Array(config['companies']) + [{ 'id' => company.id, 'added_at' => Time.current.utc.iso8601 }]
      update!('companies' => list)
    end

    def remove_company!(company)
      list = Array(config['companies']).reject { |c| (c.is_a?(Hash) ? c['id'] : c).to_i == company.id }
      update!('companies' => list)
    end

    def numbers
      entries.map { |e| e[:number] }
    end

    def pool_number?(number)
      numbers.include?(Conversation.normalize_phone(number))
    end

    def entry_for(number)
      n = Conversation.normalize_phone(number)
      entries.detect { |e| e[:number] == n }
    end

    # A pool number this buyer is not already talking to another dealer on.
    # nil when every pool number is taken for this buyer: the lead is worked by
    # email instead.
    def pick_for(buyer_phone)
      return nil unless live?

      phone = Conversation.normalize_phone(buyer_phone)
      busy = Conversation.open_now.where(pool: true, buyer_phone: phone).pluck(:sender_number)
      entries.detect { |e| busy.exclude?(e[:number]) }
    end

  end
end
