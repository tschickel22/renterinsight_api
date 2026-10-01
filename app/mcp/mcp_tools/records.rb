# frozen_string_literal: true

module McpTools
  # The records an AI app can look at, how each is scoped, searched and
  # described.
  #
  # Ids are typed ("lead:42") so search and fetch can hand them back and forth
  # without the AI having to know which table a record lives in.
  #
  # Serializers name every field. Nothing here returns dealer cost, freight,
  # holdback, pack, reserve, gross, margin, commission or profit, whatever the
  # user's role: the app's own cost gate is unreliable (see backlog), and an AI
  # transcript is an easy place for a number to travel further than intended.
  class Records
    TYPES = {
      'lead' => { resource: 'leads', path: '/crm/leads/%d', label: 'Lead' },
      'contact' => { resource: 'crm', path: '/contacts/%d', label: 'Contact' },
      'account' => { resource: 'crm', path: '/accounts/%d', label: 'Account' },
      'deal' => { resource: 'deals', path: '/deals/%d', label: 'Deal' },
      'unit' => { resource: 'inventory', path: '/inventory/%d', label: 'Inventory unit' },
      'ticket' => { resource: 'service', path: '/service/%d', label: 'Service ticket' },
      'quote' => { resource: 'finance', path: '/quotes/%d', label: 'Quote' }
    }.freeze

    QUOTE_ITEM_FIELDS = %w[name description quantity unit_price total].freeze

    attr_reader :ctx

    def initialize(ctx)
      @ctx = ctx
    end

    def self.parse_id(typed_id)
      type, id = typed_id.to_s.split(':', 2)
      raise UserError, "Ids look like lead:42 or deal:7, not #{typed_id.inspect}." unless TYPES.key?(type) && id.to_s.match?(/\A\d+\z/)

      [type, id.to_i]
    end

    def readable_types
      TYPES.keys.select { |type| ctx.can?(TYPES[type][:resource], 'read') }
    end

    # Base relation for a type, after the read permission and location access.
    def scope(type)
      ctx.authorize!(TYPES.fetch(type)[:resource], 'read')
      company = ctx.company

      case type
      when 'lead' then ctx.scope_locations(company.leads.where(is_converted: [false, nil]))
      when 'contact' then ctx.scope_locations(company.contacts.where(is_deleted: [false, nil]))
      when 'account' then ctx.scope_locations(company.accounts.where(is_deleted: [false, nil]), include_unlocated: true)
      when 'deal' then ctx.scope_locations(company.deals.where(deleted_at: nil))
      when 'unit' then ctx.scope_locations(company.vehicles.where(is_deleted: [false, nil]))
      when 'ticket' then ctx.scope_locations(company.service_tickets.where(deleted_at: nil))
      when 'quote' then ctx.scope_locations(company.quotes.where(is_deleted: [false, nil]), include_unlocated: true)
      end
    end

    def find(typed_id)
      type, id = self.class.parse_id(typed_id)
      [type, scope(type).find(id)]
    end

    def search(type, query, limit)
      term = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
      relation = scope(type)
      relation =
        case type
        when 'lead', 'contact'
          relation.where("#{relation.table_name}.first_name ILIKE :t OR #{relation.table_name}.last_name ILIKE :t OR " \
                         "(#{relation.table_name}.first_name || ' ' || #{relation.table_name}.last_name) ILIKE :t OR " \
                         "#{relation.table_name}.email ILIKE :t OR #{relation.table_name}.phone ILIKE :t", t: term)
        when 'account'
          relation.where('accounts.name ILIKE :t OR accounts.email ILIKE :t OR accounts.phone ILIKE :t OR accounts.account_number ILIKE :t', t: term)
        when 'deal'
          relation.where('deals.name ILIKE :t OR deals.deal_number ILIKE :t OR deals.customer_name ILIKE :t', t: term)
        when 'unit'
          relation.where("vehicles.stock_number ILIKE :t OR vehicles.vin ILIKE :t OR vehicles.serial_number ILIKE :t OR " \
                         "vehicles.make ILIKE :t OR vehicles.model ILIKE :t OR " \
                         "(CAST(vehicles.year AS text) || ' ' || COALESCE(vehicles.make, '') || ' ' || COALESCE(vehicles.model, '')) ILIKE :t", t: term)
        when 'ticket'
          relation.where('service_tickets.ticket_number ILIKE :t OR service_tickets.title ILIKE :t', t: term)
        when 'quote'
          relation.where('quotes.quote_number ILIKE :t', t: term)
        end
      relation.order(updated_at: :desc).limit(limit).to_a
    end

    def url(type, record)
      ctx.app_url(format(TYPES.fetch(type)[:path], record.id))
    end

    def title(type, record)
      case type
      when 'lead', 'contact' then person_name(record)
      when 'account' then record.name
      when 'deal' then [record.deal_number, record.name].compact_blank.join(' ')
      when 'unit' then [record.stock_number, record.year, record.make, record.model].compact_blank.join(' ')
      when 'ticket' then [record.ticket_number, record.title].compact_blank.join(' ')
      when 'quote' then "Quote #{record.quote_number}"
      end.presence || "#{TYPES[type][:label]} #{record.id}"
    end

    def summary(type, record)
      base = { id: "#{type}:#{record.id}", type: type, title: title(type, record), url: url(type, record) }
      base.merge(send("#{type}_summary", record)).compact
    end

    def detail(type, record)
      summary(type, record).merge(send("#{type}_detail", record)).compact
    end

    private

    def person_name(record)
      [record.first_name, record.last_name].compact_blank.join(' ')
    end

    def user_name(id)
      ctx.user_names[id.to_i] if id.present?
    end

    def location_name(id)
      ctx.location_names[id]
    end

    def iso(value)
      value&.iso8601
    end

    def address(street, city, state, zip)
      [street, city, state, zip].compact_blank.join(', ').presence
    end

    def recent_notes(entity_type, record)
      Note.where(entity_type: entity_type, entity_id: record.id.to_s).order(created_at: :desc).limit(5).map do |n|
        { at: iso(n.created_at), by: n.created_by_name, text: n.content.to_s.first(1000) }
      end
    end

    # --- leads -----------------------------------------------------------

    def lead_summary(lead)
      {
        name: person_name(lead), email: lead.email, phone: lead.phone, status: lead.status,
        owner: user_name(lead.owner_id), location: location_name(lead.location_id),
        created_at: iso(lead.created_at), last_activity_at: iso(lead.last_activity_at)
      }
    end

    def lead_detail(lead)
      {
        company_name: lead.company_name, job_title: lead.title,
        address: address(lead.street, lead.city, lead.state, lead.zip),
        budget_range: lead.budget_range, purchase_timeframe: lead.purchase_timeframe,
        preferred_contact_method: lead.preferred_contact_method,
        preferred_home: {
          type: lead.preferred_home_type, bedrooms: lead.preferred_bedrooms, bathrooms: lead.preferred_bathrooms,
          min_sqft: lead.preferred_min_sqft, max_sqft: lead.preferred_max_sqft
        }.compact.presence,
        interests: lead.interests_requirements, notes: lead.notes.to_s.first(2000).presence,
        co_applicant: [lead.co_applicant_first_name, lead.co_applicant_last_name].compact_blank.join(' ').presence,
        source_campaign: [lead.utm_source, lead.utm_campaign].compact_blank.join(' / ').presence,
        recent_activities: lead.lead_activities.order(created_at: :desc).limit(5).map do |a|
          { type: a.activity_type, subject: a.subject, status: a.status, due: iso(a.due_date), completed_at: iso(a.completed_at) }
        end,
        recent_notes: recent_notes('lead', lead)
      }
    end

    # --- contacts and accounts ------------------------------------------

    def contact_summary(contact)
      {
        name: person_name(contact), email: contact.email, phone: contact.phone,
        account: contact.account_id && ctx.company.accounts.where(id: contact.account_id).pick(:name),
        owner: user_name(contact.owner_id), location: location_name(contact.location_id)
      }
    end

    def contact_detail(contact)
      {
        job_title: contact.title, address: address(contact.street, contact.city, contact.state, contact.zip),
        email_opted_out: contact.opt_out_email, sms_opted_out: contact.opt_out_sms,
        recent_notes: recent_notes('contact', contact)
      }
    end

    def account_summary(account)
      {
        name: account.name, status: account.status, account_type: account.account_type,
        email: account.email, phone: account.phone,
        owner: user_name(account.owner_id), location: location_name(account.location_id)
      }
    end

    def account_detail(account)
      {
        website: account.website,
        address: address(account.billing_street, account.billing_city, account.billing_state, account.billing_postal_code),
        description: account.description.to_s.first(1000).presence,
        contacts: ctx.company.contacts.where(account_id: account.id, is_deleted: [false, nil]).limit(10)
                     .map { |c| { id: "contact:#{c.id}", name: person_name(c) } },
        recent_notes: recent_notes('account', account)
      }
    end

    # --- deals ------------------------------------------------------------

    def stage_label(key)
      stage = ctx.company.pipeline_stages.find { |s| (s['key'] || s[:key]).to_s.downcase == key.to_s.downcase }
      stage && (stage['name'] || stage[:name])
    end

    def deal_customer(deal)
      deal.customer_name.presence ||
        (deal.contact_id && ctx.company.contacts.where(id: deal.contact_id).pick(:first_name, :last_name)&.compact_blank&.join(' ')) ||
        (deal.account_id && ctx.company.accounts.where(id: deal.account_id).pick(:name))
    end

    def deal_summary(deal)
      {
        name: deal.name, deal_number: deal.deal_number, stage: deal.stage, stage_label: stage_label(deal.stage),
        selling_price: deal.selling_price&.to_f, probability: deal.probability,
        expected_close_date: iso(deal.expected_close_date), customer: deal_customer(deal),
        salesperson: user_name(deal.primary_salesperson_id || deal.owner_id || deal.user_id),
        unit: deal.vehicle_id && ctx.company.vehicles.where(id: deal.vehicle_id).pick(:stock_number),
        location: location_name(deal.location_id), updated_at: iso(deal.updated_at)
      }
    end

    def deal_detail(deal)
      {
        description: deal.description.to_s.first(1000).presence, delivery_date: iso(deal.delivery_date),
        payment_type: deal.payment_type, lender: deal.lender_name, down_payment: deal.down_payment&.to_f,
        total_amount: deal.total_amount&.to_f,
        stage_history: deal.deal_stage_histories.order(created_at: :desc).limit(5).map do |h|
          { from: h.previous_stage, to: h.stage, at: iso(h.created_at), by: user_name(h.changed_by_id), notes: h.notes }
        end,
        recent_notes: recent_notes('deal', deal)
      }
    end

    # --- inventory --------------------------------------------------------

    def unit_summary(unit)
      {
        stock_number: unit.stock_number, year: unit.year, make: unit.make, model: unit.model,
        home_type: unit.home_type, bedrooms: unit.bedrooms, bathrooms: unit.bathrooms&.to_f,
        square_feet: unit.square_feet, condition: unit.condition, status: unit.status,
        sale_price: unit.sale_price&.to_f, msrp: unit.msrp&.to_f,
        days_in_stock: unit.date_in_stock && (Date.current - unit.date_in_stock.to_date).to_i,
        location: location_name(unit.location_id)
      }
    end

    def unit_detail(unit)
      {
        vin: unit.vin, serial_number: unit.serial_number, width: unit.width, length: unit.length,
        community: unit.community_name, date_in_stock: iso(unit.date_in_stock),
        description: unit.description.to_s.first(1500).presence
      }
    end

    # --- service ----------------------------------------------------------

    def ticket_summary(ticket)
      {
        ticket_number: ticket.ticket_number, title: ticket.title, status: ticket.status, priority: ticket.priority,
        assigned_to: user_name(ticket.assigned_to), scheduled_date: iso(ticket.scheduled_date),
        customer: (ticket.contact_id && ctx.company.contacts.where(id: ticket.contact_id).pick(:first_name, :last_name)&.compact_blank&.join(' ')) ||
          (ticket.account_id && ctx.company.accounts.where(id: ticket.account_id).pick(:name)),
        unit: ticket.vehicle_id && ctx.company.vehicles.where(id: ticket.vehicle_id).pick(:stock_number),
        location: location_name(ticket.location_id), created_at: iso(ticket.created_at)
      }
    end

    def ticket_detail(ticket)
      {
        description: ticket.description.to_s.first(2000).presence, notes: ticket.notes.to_s.first(2000).presence,
        warranty_suspected: ticket.is_warranty_suspected, completed_date: iso(ticket.completed_date)
      }
    end

    # --- quotes -----------------------------------------------------------

    def quote_summary(quote)
      {
        quote_number: quote.quote_number, status: quote.status, total: quote.total&.to_f,
        valid_until: iso(quote.valid_until), sent_at: iso(quote.sent_at), accepted_at: iso(quote.accepted_at),
        customer: (quote.contact_id && ctx.company.contacts.where(id: quote.contact_id).pick(:first_name, :last_name)&.compact_blank&.join(' ')) ||
          (quote.account_id && ctx.company.accounts.where(id: quote.account_id).pick(:name))
      }
    end

    def quote_detail(quote)
      {
        subtotal: quote.subtotal&.to_f, tax: quote.tax&.to_f,
        items: Array(quote.items).filter_map { |item| item.is_a?(Hash) ? item.stringify_keys.slice(*QUOTE_ITEM_FIELDS) : nil }
      }
    end
  end
end
