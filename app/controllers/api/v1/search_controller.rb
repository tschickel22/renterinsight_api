class Api::V1::SearchController < ApplicationController
  before_action :set_company_scope

  def global
    # Skip authorization - search is a fundamental feature available to all users
    # Results are already scoped to @company and each module has its own RBAC
    
    query = params[:query]&.strip
    return render json: { results: [] } if query.blank? || query.length < 2
    
    results = []
    
    # CRM - Leads (use is_converted, not is_deleted)
    begin
      leads = @company.leads
                     .where(is_converted: [false, nil])
                     .where.not(status: %w[lost unqualified dead])
                     .where("first_name ILIKE :q OR last_name ILIKE :q OR email ILIKE :q OR phone ILIKE :q OR company_name ILIKE :q",
                            q: "%#{query}%")
                     .limit(5)

      results += leads.map do |lead|
        {
          id: lead.id,
          type: 'lead',
          title: lead.full_name || "#{lead.first_name} #{lead.last_name}".strip,
          subtitle: lead.company_name.presence || lead.email || lead.phone,
          badge: lead.status&.titleize,
          score: calculate_score(query, lead.first_name, lead.last_name, lead.email)
        }
      end
    rescue => e
      Rails.logger.error("Search leads error: #{e.message}")
    end
    
    # CRM - Contacts (has first_name, last_name - NOT name; NO is_deleted column)
    begin
      contacts = @company.contacts
                        .where("first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ? OR phone ILIKE ?", 
                               "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%")
                        .limit(5)
      
      results += contacts.map do |contact|
        {
          id: contact.id,
          type: 'contact',
          title: contact.full_name,
          subtitle: contact.email || contact.phone,
          badge: contact.account&.name,
          score: calculate_score(query, contact.first_name, contact.last_name, contact.email)
        }
      end
    rescue => e
      Rails.logger.error("Search contacts error: #{e.message}")
    end
    
    # CRM - Accounts
    begin
      accounts = @company.accounts
                        .where(is_deleted: [false, nil])
                        .where("name ILIKE ? OR website ILIKE ?", "%#{query}%", "%#{query}%")
                        .limit(5)
      
      results += accounts.map do |account|
        {
          id: account.id,
          type: 'account',
          title: account.name,
          subtitle: account.website || account.industry,
          badge: account.account_type&.titleize,
          score: calculate_score(query, account.name)
        }
      end
    rescue => e
      Rails.logger.error("Search accounts error: #{e.message}")
    end
    
    # CRM - Deals (NO is_deleted column in production)
    # Two match paths, both returning a 'deal' result (NO new SearchResultType):
    #   1. buyer/account/contact via deal name/number (existing behavior)
    #   2. a unit/stock# living in an ACTIVE deal_desk_scenario -> the PARENT deal, even
    #      when that unit is not the deal's primary unit (the aged cross-location case).
    # Deals with active scenarios are badged desked:true and deep-link to the desk tab.
    begin
      like = "%#{query}%"

      # Path 1 — name / deal number.
      name_matches = @company.deals
                            .where('deals.name ILIKE ? OR deals.deal_number ILIKE ?', like, like)
                            .limit(5).to_a

      # Path 2 — stock#/serial/VIN/inventory-id of a unit in an ACTIVE scenario.
      # @company.deals JOIN scenarios JOIN vehicles — never an unscoped scenario query.
      scenario_matches = @company.deals
                                .joins(deal_desk_scenarios: :vehicle)
                                .where(deal_desk_scenarios: { status: 'active' })
                                .where(
                                  'vehicles.stock_number ILIKE :q OR vehicles.serial_number ILIKE :q ' \
                                  'OR vehicles.vin ILIKE :q OR vehicles.inventory_id ILIKE :q',
                                  q: like
                                )
                                .distinct.limit(5).to_a

      stock_matched_ids = scenario_matches.map(&:id).to_set
      deals = (name_matches + scenario_matches).uniq(&:id).first(5)

      # Which of these deals carry ANY active scenario (drives the desked badge)?
      desked_ids = @company.deal_desk_scenarios.active
                          .where(deal_id: deals.map(&:id)).distinct.pluck(:deal_id).to_set

      results += deals.map do |deal|
        desked = desked_ids.include?(deal.id)
        name_score = calculate_score(query, deal.name, deal.deal_number)
        # Stock#-only matches won't score on name/number — give them a "contains" floor so
        # they surface.
        score = stock_matched_ids.include?(deal.id) ? [name_score, 60].max : name_score

        {
          id: deal.id,
          type: 'deal',
          title: deal.name,
          subtitle: deal.deal_number,
          badge: deal.stage&.titleize,
          amount: deal.value,
          desked: desked,
          url: desked ? "/deals/#{deal.id}?tab=deal_desk" : "/deals/#{deal.id}",
          score: score
        }
      end
    rescue => e
      Rails.logger.error("Search deals error: #{e.message}")
    end
    
    # Inventory - Vehicles (also matches linked deal's contact/account name —
    # LEFT JOIN deals→contact/account). Dedupe via an id subquery, NOT DISTINCT:
    # `SELECT DISTINCT vehicles.*` errors because the table has json (not jsonb) columns
    # with no equality operator. IN(...) dedupes and keeps the outer scope join-free.
    begin
      match_scope = @company.vehicles
                           .where(is_deleted: [false, nil])
                           .joins("LEFT JOIN deals ON deals.vehicle_id = vehicles.id")
                           .joins("LEFT JOIN contacts ON contacts.id = deals.contact_id")
                           .joins("LEFT JOIN accounts ON accounts.id = deals.account_id")
                           .where(
                             "vehicles.vin ILIKE :q OR vehicles.stock_number ILIKE :q OR vehicles.inventory_id ILIKE :q OR CONCAT(vehicles.year::text, ' ', vehicles.make, ' ', vehicles.model) ILIKE :q OR contacts.first_name ILIKE :q OR contacts.last_name ILIKE :q OR (COALESCE(contacts.first_name, '') || ' ' || COALESCE(contacts.last_name, '')) ILIKE :q OR accounts.name ILIKE :q",
                             q: "%#{query}%"
                           )
      vehicles = @company.vehicles.where(id: match_scope.select("vehicles.id")).limit(5)

      matched_buyers_by_vehicle = vehicle_buyer_matches(vehicles, query)

      results += vehicles.map do |vehicle|
        {
          id: vehicle.id,
          type: 'vehicle',
          title: vehicle.display_name || "#{vehicle.year} #{vehicle.make} #{vehicle.model}",
          subtitle: vehicle.inventory_id || vehicle.vin,
          badge: vehicle.status&.titleize,
          matched_buyers: matched_buyers_by_vehicle[vehicle.id] || [],
          score: calculate_score(query, vehicle.display_name, vehicle.vin, vehicle.stock_number)
        }
      end
    rescue => e
      Rails.logger.error("Search vehicles error: #{e.message}")
    end
    
    # Service - Service Tickets (has title NOT subject; NO is_deleted; has ticket_number)
    begin
      # Match the customer's name too. Tickets are found by who they are for far
      # more often than by number, and without the account join searching a
      # surname returned nothing here while the same term found the account.
      # No .distinct: :account is a belongs_to, and this table's json columns
      # have no equality operator for SELECT DISTINCT anyway.
      tickets = @company.service_tickets
                       .left_joins(:account)
                       .where("service_tickets.ticket_number ILIKE :t OR service_tickets.title ILIKE :t " \
                              "OR service_tickets.description ILIKE :t OR accounts.name ILIKE :t " \
                              "OR CAST(service_tickets.id AS TEXT) ILIKE :t",
                              t: "%#{query}%")
                       .limit(5)
      
      results += tickets.map do |ticket|
        {
          id: ticket.id,
          type: 'service_ticket',
          title: ticket.ticket_number || "Ticket ##{ticket.id}",
          subtitle: ticket.title,
          badge: ticket.status&.titleize,
          priority: ticket.priority,
          score: calculate_score(query, ticket.ticket_number, ticket.title, ticket.id.to_s)
        }
      end
    rescue => e
      Rails.logger.error("Search service_tickets error: #{e.message}")
    end
    
    # Sales - Quotes (has notes NOT title)
    begin
      quotes = @company.quotes
                      .where(is_deleted: [false, nil])
                      .where("quote_number ILIKE ? OR notes ILIKE ?", "%#{query}%", "%#{query}%")
                      .limit(5)
      
      results += quotes.map do |quote|
        {
          id: quote.id,
          type: 'quote',
          title: quote.quote_number,
          subtitle: quote.notes&.truncate(60),
          badge: quote.status&.titleize,
          amount: quote.total,
          score: calculate_score(query, quote.quote_number, quote.notes)
        }
      end
    rescue => e
      Rails.logger.error("Search quotes error: #{e.message}")
    end
    
    # Finance - Invoices (NO description column - use notes)
    begin
      invoices = @company.invoices
                        .where(is_deleted: [false, nil])
                        .where("invoice_number ILIKE ? OR notes ILIKE ?", "%#{query}%", "%#{query}%")
                        .limit(5)
      
      results += invoices.map do |invoice|
        {
          id: invoice.id,
          type: 'invoice',
          title: invoice.invoice_number,
          subtitle: invoice.notes&.truncate(60),
          badge: invoice.status&.titleize,
          amount: invoice.total,
          score: calculate_score(query, invoice.invoice_number)
        }
      end
    rescue => e
      Rails.logger.error("Search invoices error: #{e.message}")
    end
    
    # Finance - Cash Receipts
    begin
      cash_receipts = @company.cash_receipts
        .not_deleted
        .left_joins(:account)
        .where("cash_receipts.receipt_number ILIKE ? OR cash_receipts.customer_name ILIKE ? OR accounts.name ILIKE ?",
               "%#{query}%", "%#{query}%", "%#{query}%")
        .limit(5)

      results += cash_receipts.map do |cr|
        {
          id: cr.id,
          type: 'cash_receipt',
          title: cr.receipt_number,
          subtitle: cr.display_customer,
          badge: cr.status&.titleize,
          amount: cr.amount,
          score: calculate_score(query, cr.receipt_number, cr.display_customer)
        }
      end
    rescue => e
      Rails.logger.error("Search cash_receipts error: #{e.message}")
    end

    # Inventory - Parts
    begin
      parts = @company.parts
                     .where(is_deleted: [false, nil])
                     .where("name ILIKE ? OR sku ILIKE ? OR manufacturer_name ILIKE ? OR manufacturer_part_no ILIKE ? OR barcode ILIKE ?", 
                            "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%")
                     .limit(5)
      
      results += parts.map do |part|
        {
          id: part.id,
          type: 'part',
          title: part.name,
          subtitle: part.sku,
          badge: part.manufacturer_name,
          score: calculate_score(query, part.name, part.sku, part.manufacturer_name, part.manufacturer_part_no, part.barcode)
        }
      end
    rescue => e
      Rails.logger.error("Search parts error: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
    end
    
    # Operations - Purchase Orders (search PO number, supplier name, code, account number)
    begin
      pos = @company.purchase_orders
                   .left_joins(:supplier)
                   .where(is_deleted: [false, nil])
                   # Supplier is an alias subclass of Vendor, so the join lands
                   # on the vendors table. Referencing suppliers.* raised
                   # PG::UndefinedTable and dropped POs from every search.
                   .where("purchase_orders.po_number ILIKE ? OR vendors.name ILIKE ? OR vendors.code ILIKE ? OR vendors.account_number ILIKE ?",
                          "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%")
                   .limit(5)
      
      results += pos.map do |po|
        {
          id: po.id,
          type: 'purchase_order',
          title: po.po_number,
          subtitle: po.supplier&.name,
          badge: po.status&.titleize,
          amount: po.total_amount,  # Fixed: column is total_amount, not total
          score: calculate_score(query, po.po_number, po.supplier&.name, po.supplier&.code, po.supplier&.account_number)
        }
      end
    rescue => e
      Rails.logger.error("Search purchase_orders error: #{e.message}")
    end
    
    # Inventory - Suppliers (search name, code, account number)
    begin
      suppliers = @company.suppliers
                         .where(is_deleted: [false, nil])
                         .where("name ILIKE ? OR code ILIKE ? OR account_number ILIKE ?", 
                                "%#{query}%", "%#{query}%", "%#{query}%")
                         .limit(5)
      
      results += suppliers.map do |supplier|
        {
          id: supplier.id,
          type: 'supplier',
          title: supplier.name,
          subtitle: supplier.code,
          badge: supplier.active? ? 'Active' : 'Inactive',
          score: calculate_score(query, supplier.name, supplier.code, supplier.account_number)
        }
      end
    rescue => e
      Rails.logger.error("Search suppliers error: #{e.message}")
    end
    
    # Operations - Agreements
    begin
      agreements = @company.agreements
                          .where(is_deleted: [false, nil])
                          .where("title ILIKE ? OR agreement_number ILIKE ? OR category ILIKE ?",
                                 "%#{query}%", "%#{query}%", "%#{query}%")
                          .limit(5)

      results += agreements.map do |agr|
        {
          id: agr.id,
          type: 'agreement',
          title: agr.agreement_number,
          subtitle: agr.title,
          badge: agr.status&.titleize,
          score: calculate_score(query, agr.agreement_number, agr.title, agr.category)
        }
      end
    rescue => e
      Rails.logger.error("Search agreements error: #{e.message}")
    end

    # Operations - Contractors
    begin
      contractors = @company.contractors
                           .where(is_deleted: [false, nil])
                           .where("name ILIKE ? OR contact_name ILIKE ? OR email ILIKE ? OR trade_type ILIKE ?",
                                  "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%")
                           .limit(5)

      results += contractors.map do |contractor|
        {
          id: contractor.id,
          type: 'contractor',
          title: contractor.name,
          subtitle: contractor.contact_name || contractor.email,
          badge: contractor.trade_type&.titleize,
          score: calculate_score(query, contractor.name, contractor.contact_name, contractor.email, contractor.trade_type)
        }
      end
    rescue => e
      Rails.logger.error("Search contractors error: #{e.message}")
    end

    # Workflow Rules
    begin
      rules = @company.workflow_rules
                      .where("name ILIKE ?", "%#{query}%")
                      .limit(5)
      results += rules.map do |r|
        {
          id: r.id,
          type: 'workflow_rule',
          title: r.name,
          subtitle: r.trigger&.dig('event_type'),
          badge: r.status&.titleize,
          score: calculate_score(query, r.name)
        }
      end
    rescue => e
      Rails.logger.error("Search workflow_rules error: #{e.message}")
    end

    # Sort by relevance score (higher = better match)
    results.sort_by! { |r| -r[:score] }
    
    # Limit total results to 30
    results = results.take(30)
    
    render json: { results: results }
  end
  
  private

  # For each vehicle in `vehicles_scope`, find linked deals whose contact or
  # account name matches `query` and return { vehicle_id => [{name:, deal_id:}, ...] }.
  # Lets the FE surface "matched via Jane Doe" instead of an unexplained hit.
  def vehicle_buyer_matches(vehicles_scope, query)
    return {} if query.blank?

    vehicle_ids = vehicles_scope.map(&:id)
    return {} if vehicle_ids.empty?

    deals = @company.deals
      .where(vehicle_id: vehicle_ids)
      .joins("LEFT JOIN contacts ON contacts.id = deals.contact_id")
      .joins("LEFT JOIN accounts ON accounts.id = deals.account_id")
      .where(
        "contacts.first_name ILIKE :q OR contacts.last_name ILIKE :q OR (COALESCE(contacts.first_name, '') || ' ' || COALESCE(contacts.last_name, '')) ILIKE :q OR accounts.name ILIKE :q",
        q: "%#{query}%"
      )
      .includes(:contact, :account)

    deals.each_with_object({}) do |deal, acc|
      name = if deal.contact
               "#{deal.contact.first_name} #{deal.contact.last_name}".strip
             else
               deal.account&.name
             end
      next if name.blank?
      acc[deal.vehicle_id] ||= []
      acc[deal.vehicle_id] << { name: name, deal_id: deal.id }
    end
  end

  # Calculate relevance score (0-100)
  # Exact match = 100, starts with = 75, contains = 50
  def calculate_score(query, *fields)
    query_lower = query.downcase
    max_score = 0
    
    fields.compact.each do |field|
      field_lower = field.to_s.downcase
      
      if field_lower == query_lower
        max_score = [max_score, 100].max
      elsif field_lower.start_with?(query_lower)
        max_score = [max_score, 75].max
      elsif field_lower.include?(query_lower)
        max_score = [max_score, 50].max
      end
    end
    
    max_score
  end
end
