# frozen_string_literal: true

module Accounts
  # Gives an imported household account its person (Tom, 2026-11-22).
  #
  # Our dealers sell to households, so an account is usually named after the
  # buyer ("Jeretta Smuts"). An import that brings in accounts with a name,
  # email and phone but no contact leaves every deal for them with no Buyer.
  # This makes the primary contact from the account: name split into first and
  # last, plus its email, phone and billing address. "John & Mary Smith"
  # becomes two contacts.
  #
  # Only for dealer industries (manufactured housing, RV). A software or
  # property management account is a business, not a person. Names that do not
  # read as a person ("Smith Family", "Smith, John", "Acme Homes LLC") are
  # skipped and reported, never guessed.
  class HouseholdContact
    INDUSTRIES = %w[manufactured_housing rv].freeze
    NOT_A_PERSON = /\b(family|household|llc|l\.l\.c|inc|corp|corporation|company|co\.|homes?|trust|estate|church|ministr(y|ies)|propert(y|ies)|services?|group|partners|realty|bank|credit|mortgage|county|city of)\b/i

    Result = Struct.new(:status, :reason, :contacts, keyword_init: true)

    def self.applies_to?(company) = INDUSTRIES.include?(company&.industry.to_s)

    def self.ensure!(account) = new(account).ensure!

    def initialize(account)
      @account = account
    end

    def ensure!
      return skip('not a dealer company') unless self.class.applies_to?(@account.company)
      return skip('already has a contact') if Contact.where(account_id: @account.id).where(is_deleted: [false, nil]).exists?

      people = split(@account.name)
      return skip("name does not read as a person: #{@account.name}") unless people

      contacts = people.each_with_index.map do |(first, last), i|
        Contact.create!(
          company_id: @account.company_id, account_id: @account.id, location_id: @account.location_id,
          owner_id: @account.owner_id, first_name: first, last_name: last, is_primary: i.zero?,
          email: (@account.email if i.zero?), phone: (@account.phone if i.zero?),
          street: @account.billing_street, city: @account.billing_city, state: @account.billing_state,
          zip: @account.billing_postal_code, country: @account.billing_country,
          notes: 'Made from the imported account.'
        )
      end
      Result.new(status: :created, contacts: contacts)
    rescue ActiveRecord::RecordInvalid => e
      skip(e.record.errors.full_messages.to_sentence)
    end

    private

    def skip(reason) = Result.new(status: :skipped, reason: reason, contacts: [])

    # [[first, last], ...] or nil when the name is not plainly a person's.
    def split(name)
      name = name.to_s.squish
      return nil if name.blank? || name.include?(',') || name.match?(/\d/) || name.match?(NOT_A_PERSON)

      words = name.split(' ')
      return nil if words.size > 5

      joiner = words.index { |w| w == '&' || w.casecmp('and').zero? }
      if joiner
        # "John & Mary Smith": two people, one last name.
        return nil unless joiner == 1 && words.size >= 4

        last = words[3..].join(' ')
        return [[words[0], last], [words[2], last]]
      end

      return [[words.first, nil]] if words.size == 1

      [[words.first, words[1..].join(' ')]]
    end
  end
end
