module Messaging
  module MergeTagResolver
    TAG_PATTERN = /\{\{\s*([a-z0-9_.]+)\s*\}\}/i

    CROSS_ENTITY_NAMESPACES = %w[deal contact account vehicle service_ticket].freeze

    def self.resolve(text, context)
      return '' if text.nil?
      text.to_s.gsub(TAG_PATTERN) do
        path = $1.to_s.strip.downcase
        value = lookup(path, context)
        value.nil? ? '' : value.to_s
      end
    end

    def self.build_context(recipient:, company:, rep: nil, campaign_send: nil, urls: {})
      {
        'first_name' => extract_first_name(recipient),
        'last_name'  => extract_last_name(recipient),
        'full_name'  => extract_full_name(recipient),
        'email'      => extract_email(recipient),
        'phone'      => extract_phone(recipient),
        'rep_name'   => rep_full_name(rep),
        'rep_email'  => rep&.try(:email),
        'rep_phone'  => rep&.try(:phone),
        'company' => {
          'name'    => company&.name,
          'phone'   => company&.try(:phone),
          'email'   => company&.try(:email),
          'website' => company&.try(:website)
        },
        'public_inventory_url' => urls[:public_inventory_url] || urls['public_inventory_url'],
        'unsubscribe_url'      => urls[:unsubscribe_url]      || urls['unsubscribe_url'],
        'view_in_browser_url'  => urls[:view_in_browser_url]  || urls['view_in_browser_url'],
        'campaign_send_id'     => campaign_send&.id
      }
    end

    # Resolves cross-entity merge tags (deal.*, contact.*, account.*, vehicle.*, service_ticket.*)
    # for the given recipient. Mutates and returns the context hash.
    #
    # N+1 by design for V1: each recipient triggers up to ~5 lookups. Acceptable
    # for current campaign sizes; batch preloading can come later.
    def self.enrich_context(context, recipient:, company:)
      return context unless recipient && company

      started_at = Time.current
      deal, contact, account, vehicle, ticket = resolve_cross_entities(recipient, company)

      apply_deal_fields(context, deal)
      apply_contact_fields(context, contact)
      apply_account_fields(context, account)
      apply_vehicle_fields(context, vehicle)
      apply_service_ticket_fields(context, ticket)

      Rails.logger.debug do
        "[MergeTagResolver] enrich_context recipient=#{recipient.class.name}##{recipient.id} " \
          "took=#{((Time.current - started_at) * 1000).round(1)}ms"
      end
      context
    end

    def self.lookup(path, context)
      parts = path.split('.')
      current = context
      parts.each_with_index do |part, idx|
        return nil if current.nil?
        if current.is_a?(Hash)
          # Try the full remaining dotted key first (so 'deal.name' resolves
          # even when stored as a single string key on the top-level hash).
          if idx.zero?
            remaining = parts[idx..].join('.')
            if current.key?(remaining) || current.key?(remaining.to_sym)
              return current[remaining] || current[remaining.to_sym]
            end
          end
          current = current[part] || current[part.to_sym]
        elsif current.respond_to?(part)
          current = current.public_send(part)
        else
          current = nil
        end
      end
      current
    end

    def self.extract_first_name(record)
      return nil unless record
      first = record.try(:first_name)
      return first if first.present?
      record.respond_to?(:name) ? record.name.to_s.split(/\s+/).first : nil
    end

    def self.extract_last_name(record)
      return nil unless record
      last = record.try(:last_name)
      return last if last.present?
      record.respond_to?(:name) ? record.name.to_s.split(/\s+/, 2).last : nil
    end

    def self.extract_full_name(record)
      return nil unless record
      first = extract_first_name(record)
      last = extract_last_name(record)
      combined = [first, last].compact.reject(&:blank?).join(' ')
      return combined if combined.present?
      record.try(:name) || record.try(:email)
    end

    def self.extract_email(record)
      record&.try(:email)
    end

    def self.extract_phone(record)
      record&.try(:phone)
    end

    def self.rep_full_name(rep)
      return nil unless rep
      [rep.try(:first_name), rep.try(:last_name)].compact.reject(&:blank?).join(' ').presence ||
        rep.try(:name) || rep.try(:email)
    end

    # ---- internal: cross-entity resolution -----------------------------------

    def self.resolve_cross_entities(recipient, company)
      case recipient
      when Lead    then resolve_for_lead(recipient, company)
      when Contact then resolve_for_contact(recipient, company)
      when Account then resolve_for_account(recipient, company)
      else
        [nil, nil, nil, nil, nil]
      end
    end

    def self.resolve_for_lead(lead, company)
      account = lead.try(:converted_account)
      contact_ids = account ? Contact.where(company_id: company.id, account_id: account.id).pluck(:id) : []

      contact = if contact_ids.any?
                  Contact.where(id: contact_ids).order(created_at: :desc).first
                end

      deal_scope = company.deals
      deal = if contact_ids.any? && account
               deal_scope.where('contact_id IN (?) OR account_id = ?', contact_ids, account.id).order(created_at: :desc).first
             elsif contact_ids.any?
               deal_scope.where(contact_id: contact_ids).order(created_at: :desc).first
             elsif account
               deal_scope.where(account_id: account.id).order(created_at: :desc).first
             end

      vehicle = lead.try(:vehicle) || deal&.vehicle

      ticket = if contact_ids.any?
                 company.service_tickets.where(contact_id: contact_ids).order(created_at: :desc).first
               end

      [deal, contact, account, vehicle, ticket]
    end

    def self.resolve_for_contact(contact, company)
      deal = company.deals.where(contact_id: contact.id).order(created_at: :desc).first
      account = contact.try(:account)
      vehicle = deal&.vehicle ||
                Vehicle.joins(:deals).where(company_id: company.id, deals: { contact_id: contact.id }).first
      ticket = company.service_tickets.where(contact_id: contact.id).order(created_at: :desc).first
      [deal, nil, account, vehicle, ticket]
    end

    def self.resolve_for_account(account, company)
      deal = company.deals.where(account_id: account.id).order(created_at: :desc).first
      contact = company.contacts.where(account_id: account.id).order(created_at: :desc).first
      vehicle = deal&.vehicle
      ticket = company.service_tickets
                      .joins('LEFT JOIN contacts ON contacts.id = service_tickets.contact_id')
                      .where(contacts: { account_id: account.id })
                      .order('service_tickets.created_at DESC')
                      .first
      [deal, contact, nil, vehicle, ticket]
    end

    def self.apply_deal_fields(context, deal)
      vehicle = deal&.vehicle
      vehicle_desc = vehicle ? [vehicle.year, vehicle.make, vehicle.model].compact.reject(&:blank?).join(' ') : ''
      owner = deal&.try(:owner)

      context['deal.name']                = deal&.name.to_s
      context['deal.stage']                = deal&.stage.to_s
      context['deal.value']                = format_decimal(deal&.value)
      context['deal.selling_price']        = format_decimal(deal&.selling_price)
      context['deal.probability']          = deal&.probability.to_s
      context['deal.expected_close_date']  = deal&.expected_close_date.to_s
      context['deal.deal_number']          = deal&.deal_number.to_s
      context['deal.owner_name']           = rep_full_name(owner).to_s
      context['deal.owner_email']          = owner&.try(:email).to_s
      context['deal.customer_name']        = deal ? deal.try(:customer_display_name).to_s : ''
      context['deal.vehicle_description']  = vehicle_desc
    end

    def self.apply_contact_fields(context, contact)
      context['contact.first_name']   = contact&.first_name.to_s
      context['contact.last_name']    = contact&.last_name.to_s
      context['contact.full_name']    = contact ? extract_full_name(contact).to_s : ''
      context['contact.email']        = contact&.email.to_s
      context['contact.phone']        = contact&.phone.to_s
      context['contact.title']        = contact&.try(:title).to_s
      context['contact.company_name'] = contact&.account&.name.to_s
    end

    def self.apply_account_fields(context, account)
      context['account.name']         = account&.name.to_s
      context['account.email']        = account&.try(:email).to_s
      context['account.phone']        = account&.try(:phone).to_s
      context['account.website']      = account&.try(:website).to_s
      context['account.industry']     = account&.try(:industry).to_s
      context['account.account_type'] = account&.try(:account_type).to_s
    end

    def self.apply_vehicle_fields(context, vehicle)
      desc = vehicle ? [vehicle.year, vehicle.make, vehicle.model].compact.reject(&:blank?).join(' ') : ''
      context['vehicle.year']          = vehicle&.year.to_s
      context['vehicle.make']          = vehicle&.make.to_s
      context['vehicle.model']         = vehicle&.model.to_s
      context['vehicle.description']   = desc
      context['vehicle.serial_number'] = vehicle&.try(:serial_number).to_s
      context['vehicle.stock_number']  = vehicle&.try(:stock_number).to_s
      context['vehicle.sale_price']    = format_decimal(vehicle&.try(:sale_price))
      context['vehicle.status']        = vehicle&.try(:status).to_s
    end

    def self.apply_service_ticket_fields(context, ticket)
      number = ticket ? (ticket.try(:ticket_number) || "ST-#{ticket.id}") : ''
      context['service_ticket.ticket_number'] = number.to_s
      context['service_ticket.title']         = ticket&.try(:title).to_s
      context['service_ticket.status']        = ticket&.try(:status).to_s
      context['service_ticket.priority']      = ticket&.try(:priority).to_s
    end

    def self.format_decimal(value)
      return '' if value.nil?
      bd = BigDecimal(value.to_s)
      bd.frac.zero? ? bd.to_i.to_s : bd.to_s('F')
    rescue ArgumentError, TypeError
      value.to_s
    end
  end
end
