# frozen_string_literal: true

module PhoneCalls
  # "Who is calling?" for a dealer's phone system: the lead, contact or account
  # that owns a phone number, shaped for a screen pop. The phone system checks
  # that a returned phone equals the number it asked about, so the number asked
  # is echoed back as `phone` (the match is on its last ten digits anyway).
  class Lookup
    TYPES = { lead: 'Lead', contact: 'Contact', account: 'Account' }.freeze
    PATHS = { lead: '/crm/leads', contact: '/contacts', account: '/accounts' }.freeze

    def initialize(company)
      @company = company
    end

    # One best match (an array so the template can address `contacts.id`), or [].
    def by_number(number)
      digits = number.to_s.gsub(/\D/, '')
      return [] if digits.length < 7

      match = IdentityResolver.new(@company, phone: digits).resolve
      match ? [present(match.type, match.record, phone: number.to_s)] : []
    end

    # "lead-12" / "contact-4" / "account-9" back to a record of this company.
    def find_entity(entity_id)
      type, id = entity_id.to_s.downcase.split('-', 2)
      return nil if id.blank? || id !~ /\A\d+\z/

      case type
      when 'lead' then @company.leads.find_by(id: id)
      when 'contact' then @company.contacts.find_by(id: id)
      when 'account' then @company.accounts.find_by(id: id)
      end
    end

    def self.entity_id(record)
      "#{record.class.name.downcase}-#{record.id}"
    end

    private

    def present(type, record, phone: nil)
      first, last =
        if type == :account
          [record.name, '']
        else
          [record.first_name, record.last_name]
        end
      {
        id: "#{type}-#{record.id}",
        type: TYPES[type],
        first_name: first.to_s,
        last_name: last.to_s,
        company: (type == :account ? '' : record.try(:company_name).to_s),
        email: record.try(:email).to_s,
        phone: (phone.presence || record.phone).to_s,
        mobile: record.phone.to_s,
        url: "#{app_url}#{PATHS[type]}/#{record.id}"
      }
    end

    def app_url
      @app_url ||= Brand.current(company: @company).app_url.to_s.chomp('/')
    end
  end
end
