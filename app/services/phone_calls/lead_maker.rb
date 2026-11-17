# frozen_string_literal: true

module PhoneCalls
  # A new lead for a phone number nobody in the CRM has, when a dealer's phone
  # system (3CX) reports a call or a text conversation with it. Owned the way a
  # text from a new person is (UnmatchedTextRouting, Company Settings,
  # Communications, SMS, "Texts from new people"), at the dealer's inbound
  # location.
  #
  # 3CX has no automatic "create a contact" step of its own: its contact
  # creation scenario (CreateContactRecordFromClient) runs only when someone
  # asks for it in the 3CX app. So call and chat journaling ask for this
  # instead, when the template's "Create a lead for unknown numbers" is on.
  #
  # Needs a full ten digit number. 3CX may cut a number to its "digits to
  # match" (7 at Easy Homesource), and a lead with seven digits cannot be
  # called back or matched again.
  class LeadMaker
    SOURCES = { call: 'Phone call', text: 'Text message' }.freeze

    def initialize(company)
      @company = company
    end

    def self.full_number?(number)
      number.to_s.gsub(/\D/, '').length >= 10
    end

    # kind: :call or :text. Returns the new lead, or nil when the number is too
    # short. first_name/last_name/email come from 3CX's own create-contact form.
    def create!(number:, kind:, first_name: nil, last_name: nil, email: nil, company_name: nil, note: nil)
      return nil unless self.class.full_number?(number)

      source = SourceResolverService.resolve(company: @company, source_name: SOURCES.fetch(kind))
      word = kind == :text ? 'Text from' : 'Caller'
      @company.leads.create!(
        first_name: first_name.presence || word, last_name: last_name.presence || self.class.pretty(number),
        phone: number.to_s, email: email.presence, company_name: company_name.presence,
        status: 'new', origin: kind == :text ? Lead::ORIGIN_SMS : Lead::ORIGIN_API,
        source_id: source&.id, owner_id: UnmatchedTextRouting.new(@company).next_owner_id,
        location_id: @company.inbound_lead_location&.id,
        notes: note.presence || "Created by the phone system for a #{kind == :text ? 'text' : 'call'} from #{number}."
      )
    end

    def self.pretty(number)
      d = number.to_s.gsub(/\D/, '').last(10)
      d.length == 10 ? "(#{d[0, 3]}) #{d[3, 3]}-#{d[6, 4]}" : number.to_s
    end
  end
end
