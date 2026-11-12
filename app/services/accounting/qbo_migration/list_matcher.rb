# frozen_string_literal: true

module Accounting
  module QboMigration
    # Finds the DealerTide record each QuickBooks customer and vendor already
    # is, so the switch links it instead of making a second copy.
    #
    # Customers are looked for among contacts, then leads (a lead the
    # QuickBooks customer already is gets converted, the way Convert does it).
    # Vendors among vendors. In order: the QuickBooks id, email, phone, then
    # name with punctuation and business endings (Inc, LLC, Co) ignored.
    #
    # Each row comes back as one of:
    #   link          a contact or vendor it already is
    #   convert_lead  an open lead it already is
    #   new           nothing found; the switch creates one
    #   needs_choice  more than one possible match, or a lead found by name
    #                 only; a person picks (Wizard#update_list_choices!)
    # A choice the person saved (config['list_choices']) wins over all of it.
    class ListMatcher
      KINDS = %w[customers vendors].freeze
      SUFFIXES = %w[inc incorporated llc l l c co company corp corporation ltd limited pllc plc lp llp].freeze
      # Plain rows: matching reads only these columns, and partial models
      # trip the models' after_initialize hooks.
      Person = Struct.new(:id, :first_name, :last_name, :company_name, :email, :phone, :quickbooks_id)
      VendorRow = Struct.new(:id, :name, :contact_name, :email, :phone, :quickbooks_id, :qb_vendor_id)

      def self.normalize_name(value)
        s = value.to_s.downcase.gsub('&', ' and ').gsub(/[^a-z0-9 ]/, ' ').squeeze(' ').strip
        s = s.sub(/\Athe /, '')
        words = s.split
        words.pop while words.size > 1 && SUFFIXES.include?(words.last)
        words.join(' ')
      end

      def self.normalize_phone(value)
        digits = value.to_s.gsub(/\D/, '')
        digits = digits[1..] if digits.size == 11 && digits.start_with?('1')
        digits.size == 10 ? digits : nil
      end

      def self.normalize_email(value)
        value.to_s.strip.downcase.presence
      end

      def initialize(company, choices: {})
        @company = company
        @choices = choices || {}
      end

      # [{ external_id, name, email, phone, company_name, status, match, candidates, reason }]
      def customers(list)
        Array(list).map { |c| row('customers', c, customer_match(c)) }
      end

      def vendors(list)
        Array(list).map { |v| row('vendors', v, vendor_match(v)) }
      end

      def rows(kind, list)
        kind == 'customers' ? customers(list) : vendors(list)
      end

      # Contacts, open leads or vendors to pick from by hand.
      def search(kind, query, limit: 20)
        q = query.to_s.strip
        return [] if q.size < 2

        like = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"
        if kind == 'vendors'
          vendor_scope.where('name ILIKE :q OR email ILIKE :q OR contact_name ILIKE :q OR phone ILIKE :q', q: like)
                      .order(:name).limit(limit).map { |v| target('vendor', v) }
        else
          contacts = contact_scope.where("first_name ILIKE :q OR last_name ILIKE :q OR (first_name || ' ' || COALESCE(last_name, '')) ILIKE :q " \
                                         'OR company_name ILIKE :q OR email ILIKE :q OR phone ILIKE :q', q: like)
                                  .order(:last_name, :first_name).limit(limit).map { |c| target('contact', c) }
          leads = lead_scope.where("first_name ILIKE :q OR last_name ILIKE :q OR (first_name || ' ' || COALESCE(last_name, '')) ILIKE :q " \
                                   'OR company_name ILIKE :q OR email ILIKE :q OR phone ILIKE :q', q: like)
                            .order(:last_name, :first_name).limit(limit).map { |l| target('lead', l) }
          contacts + leads
        end
      end

      # The record a target ({ 'type', 'id' }) names, or nil when it is gone.
      def find_target(type, id)
        case type
        when 'contact' then contact_scope.find_by(id: id)
        when 'lead' then lead_scope.find_by(id: id)
        when 'vendor' then vendor_scope.find_by(id: id)
        end
      end

      def target(type, record)
        name, detail =
          case type
          when 'vendor'
            [record.name, [record.email, record.phone].compact_blank.first]
          else
            person = [record.first_name, record.last_name].compact_blank.join(' ')
            [person.presence || record.company_name.presence || "#{type.capitalize} #{record.id}",
             [record.try(:company_name).presence && person.present? ? record.company_name : nil, record.email, record.phone].compact_blank.first]
          end
        { type: type, id: record.id, name: name, detail: detail }
      end

      private

      def row(kind, q, found)
        chosen = @choices.dig(kind, q['external_id'].to_s)
        out = {
          external_id: q['external_id'].to_s, name: display_name(q), email: q['email'], phone: q['phone'],
          company_name: q['company_name'], candidates: found[:candidates] || []
        }
        if chosen
          if chosen['action'] == 'new'
            return out.merge(status: 'new', reason: 'chosen', match: nil)
          end

          rec = find_target(chosen['type'], chosen['id'])
          if rec
            status = chosen['type'] == 'lead' ? 'convert_lead' : 'link'
            return out.merge(status: status, reason: 'chosen', match: target(chosen['type'], rec))
          end
          # The chosen record is gone: fall back to what matching finds.
        end
        out.merge(status: found[:status], reason: found[:reason], match: found[:match])
      end

      def display_name(q)
        q['name'].presence || q['company_name'].presence ||
          [q['first_name'], q['last_name']].compact_blank.join(' ').presence || "QuickBooks #{q['external_id']}"
      end

      def customer_match(c)
        ext = c['external_id'].to_s
        if (hit = contacts_by_qbo[ext])
          return sure('contact', hit, 'quickbooks_id')
        end

        email = self.class.normalize_email(c['email'])
        phone = self.class.normalize_phone(c['phone'])
        [[email, contacts_by_email, 'email'], [phone, contacts_by_phone, 'phone']].each do |key, index, reason|
          next if key.nil?

          hits = index[key] || []
          return sure('contact', hits.first, reason) if hits.size == 1
          return choose('contact', hits, reason) if hits.size > 1
        end

        names = customer_names(c)
        hits = names.flat_map { |n| contacts_by_name[n] || [] }.uniq
        return sure('contact', hits.first, 'name') if hits.size == 1
        return choose('contact', hits, 'name') if hits.size > 1

        [[email, leads_by_email, 'email'], [phone, leads_by_phone, 'phone']].each do |key, index, reason|
          next if key.nil?

          hits = index[key] || []
          return { status: 'convert_lead', reason: reason, match: target('lead', hits.first), candidates: [] } if hits.size == 1
          return choose('lead', hits, reason) if hits.size > 1
        end

        # A lead found by name alone could be someone else with the same
        # name, so a person decides.
        hits = names.flat_map { |n| leads_by_name[n] || [] }.uniq
        return choose('lead', hits, 'name') if hits.any?

        { status: 'new', reason: nil, match: nil, candidates: [] }
      end

      def vendor_match(v)
        ext = v['external_id'].to_s
        if (hit = vendors_by_qbo[ext])
          return sure('vendor', hit, 'quickbooks_id')
        end

        email = self.class.normalize_email(v['email'])
        phone = self.class.normalize_phone(v['phone'])
        [[email, vendors_by_email, 'email'], [phone, vendors_by_phone, 'phone']].each do |key, index, reason|
          next if key.nil?

          hits = index[key] || []
          return sure('vendor', hits.first, reason) if hits.size == 1
          return choose('vendor', hits, reason) if hits.size > 1
        end

        names = [v['name'], v['company_name']].map { |n| self.class.normalize_name(n) }.compact_blank.uniq
        hits = names.flat_map { |n| vendors_by_name[n] || [] }.uniq
        return sure('vendor', hits.first, 'name') if hits.size == 1
        return choose('vendor', hits, 'name') if hits.size > 1

        { status: 'new', reason: nil, match: nil, candidates: [] }
      end

      def sure(type, record, reason)
        { status: 'link', reason: reason, match: target(type, record), candidates: [] }
      end

      def choose(type, records, reason)
        { status: 'needs_choice', reason: reason, match: nil, candidates: records.first(10).map { |r| target(type, r) } }
      end

      def customer_names(c)
        person = [c['first_name'], c['last_name']].compact_blank.join(' ')
        [person, c['company_name'], c['name']].map { |n| self.class.normalize_name(n) }.compact_blank.uniq
      end

      def person_names(rec)
        person = [rec.first_name, rec.last_name].compact_blank.join(' ')
        [person, rec.company_name].map { |n| self.class.normalize_name(n) }.compact_blank.uniq
      end

      def contact_scope
        @company.contacts.where(is_deleted: false)
      end

      def lead_scope
        @company.leads.where(is_converted: [false, nil])
      end

      def vendor_scope
        @company.vendors.where(is_deleted: [false, nil])
      end

      def contact_records
        @contacts ||= contact_scope.pluck(:id, :first_name, :last_name, :company_name, :email, :phone, :quickbooks_id)
                                   .map { |a| Person.new(*a) }
      end

      def lead_records
        @leads ||= lead_scope.pluck(:id, :first_name, :last_name, :company_name, :email, :phone)
                             .map { |a| Person.new(*a) }
      end

      def vendor_records
        @vendors ||= vendor_scope.pluck(:id, :name, :contact_name, :email, :phone, :quickbooks_id, :qb_vendor_id)
                                 .map { |a| VendorRow.new(*a) }
      end

      def contacts_by_qbo
        @contacts_by_qbo ||= contact_records.select { |c| c.quickbooks_id.present? }.index_by { |c| c.quickbooks_id.to_s }
      end

      def contacts_by_email
        @contacts_by_email ||= group(contact_records) { |c| [self.class.normalize_email(c.email)] }
      end

      def contacts_by_phone
        @contacts_by_phone ||= group(contact_records) { |c| [self.class.normalize_phone(c.phone)] }
      end

      def contacts_by_name
        @contacts_by_name ||= group(contact_records) { |c| person_names(c) }
      end

      def leads_by_email
        @leads_by_email ||= group(lead_records) { |l| [self.class.normalize_email(l.email)] }
      end

      def leads_by_phone
        @leads_by_phone ||= group(lead_records) { |l| [self.class.normalize_phone(l.phone)] }
      end

      def leads_by_name
        @leads_by_name ||= group(lead_records) { |l| person_names(l) }
      end

      def vendors_by_qbo
        @vendors_by_qbo ||= vendor_records.each_with_object({}) do |v, h|
          h[v.quickbooks_id.to_s] ||= v if v.quickbooks_id.present?
          h[v.qb_vendor_id.to_s] ||= v if v.qb_vendor_id.present?
        end
      end

      def vendors_by_email
        @vendors_by_email ||= group(vendor_records) { |v| [self.class.normalize_email(v.email)] }
      end

      def vendors_by_phone
        @vendors_by_phone ||= group(vendor_records) { |v| [self.class.normalize_phone(v.phone)] }
      end

      def vendors_by_name
        @vendors_by_name ||= group(vendor_records) { |v| [self.class.normalize_name(v.name)] }
      end

      def group(records)
        records.each_with_object(Hash.new { |h, k| h[k] = [] }) do |r, h|
          Array(yield(r)).compact_blank.uniq.each { |key| h[key] << r }
        end
      end
    end
  end
end
