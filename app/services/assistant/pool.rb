# frozen_string_literal: true

module Assistant
  # The shared texting numbers a dealer's assistant uses until the dealer's own
  # number is live (backlog E96, phase 3). Platform setting 'assistant_pool':
  #
  #   { "live" => true,
  #     "numbers" => [{ "number" => "+19704632673", "messaging_service_sid" => "MG..." }] }
  #
  # Each environment holds its own numbers on its own Messaging Service and A2P
  # campaign. Nothing is sent from the pool until "live" is true, which is set by
  # hand once the campaign is VERIFIED and a test text has arrived on a T-Mobile
  # handset (CLAUDE.md, A2P 10DLC delivery).
  module Pool
    KEY = 'assistant_pool'
    MAX_DAYS = 45

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

    # A dealer stays on the pool at most MAX_DAYS after their first pool text.
    def within_allowance?(company)
      first = Conversation.where(company_id: company.id, pool: true).minimum(:started_at)
      first.nil? || first > MAX_DAYS.days.ago
    end
  end
end
