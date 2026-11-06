# frozen_string_literal: true

module PhoneCalls
  # "Who is calling?" for a dealer's phone system: the lead, contact or account
  # that owns a phone number, shaped for a screen pop. The phone system checks
  # that a returned phone equals the number it asked about, so the number asked
  # is echoed back as `phone` (the match is on its last ten digits anyway).
  #
  # 3CX cuts the number to its "digits to match" setting before asking (7 on
  # Easy Homesource's, so 352-584-9356 arrived as 5849356). Anything from 7 to 9
  # digits is matched against the END of stored numbers; 10 or more goes through
  # IdentityResolver's usual last-ten-digits rule.
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

      type, record = resolve(digits)
      record ? [present(type, record, phone: number.to_s)] : []
    end

    # [type, record] for the best owner of a number, or nil.
    # Preference: open lead, contact, account, converted lead (as IdentityResolver).
    def resolve(number)
      digits = number.to_s.gsub(/\D/, '')
      return nil if digits.length < 7

      if digits.length >= 10
        m = IdentityResolver.new(@company, phone: digits).resolve
        return m && [m.type, m.record]
      end

      tail = "right(regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g'), #{digits.length}) = ?"
      leads = @company.leads.where(tail, digits).order(updated_at: :desc).to_a
      open_lead = leads.find { |l| !l.try(:is_converted) }
      return [:lead, open_lead] if open_lead

      contact = @company.contacts.where(is_deleted: false).where(tail, digits).order(updated_at: :desc).first
      return [:contact, contact] if contact

      account = @company.accounts.where(is_deleted: false).where(tail, digits).order(updated_at: :desc).first
      return [:account, account] if account

      leads.first && [:lead, leads.first]
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
