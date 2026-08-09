# frozen_string_literal: true

# Dashboard Metrics Service
# Calculates data for all dashboard cards
# Each method returns data for a specific card type

class DashboardMetricsService
  attr_reader :company, :current_user, :date_range

  def initialize(company, current_user, date_range = {})
    @company = company
    @current_user = current_user
    @date_range = parse_date_range(date_range)
  end

  # Delegate to Company#*_stage_keys so every dashboard method resolves
  # won/lost stages the same way as the rest of the app.
  def won_stages
    @company.won_stage_keys
  end

  def lost_stages
    @company.lost_stage_keys
  end

  def closed_stages
    @company.closed_deal_stage_keys
  end

  # ==================== REVENUE SUMMARY CARD ====================
  # Returns: { value, trend_percentage, trend_direction, sparkline_data, drill_down_url }
  def revenue_summary
    # Get revenue for current period
    current_revenue = calculate_revenue(@date_range[:start_date], @date_range[:end_date])
    
    # Get revenue for previous period (for trend calculation)
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    previous_revenue = calculate_revenue(previous_start, previous_end)
    
    # Calculate trend
    trend = calculate_trend(current_revenue, previous_revenue)
    
    # Generate sparkline data (last 30 days)
    sparkline_data = generate_revenue_sparkline
    
    {
      value: current_revenue,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      sparkline_data: sparkline_data,
      drill_down_url: '/finance/payments',
      formatted_value: format_currency(current_revenue)
    }
  end

  # ==================== DEALS COUNT CARD ====================
  # Returns: { value, trend_percentage, trend_direction, sparkline_data, drill_down_url, by_stage }
  def deals_count
    # Get ALL active deals (exclude closed_won and closed_lost)
    # This matches what the Deals page shows - no date filter on active deals
    current_deals = @company.deals
      .where.not(stage: closed_stages)
    
    current_count = current_deals.count
    
    # For trend: count NEW deals created in current period vs previous period
    new_deals_current = @company.deals
      .where(created_at: @date_range[:start_date]..@date_range[:end_date])
      .where.not(stage: closed_stages)
      .count
    
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    new_deals_previous = @company.deals
      .where(created_at: previous_start..previous_end)
      .where.not(stage: closed_stages)
      .count
    
    # Calculate trend based on new deals created
    trend = calculate_trend(new_deals_current, new_deals_previous)
    
    # Generate sparkline (deals created per day, last 30 days)
    sparkline_data = generate_deals_sparkline
    
    # Breakdown by stage (all active deals)
    by_stage = current_deals.group(:stage).count
    
    {
      value: current_count,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      sparkline_data: sparkline_data,
      drill_down_url: '/deals',
      by_stage: by_stage
    }
  end

  # ==================== LEADS COUNT CARD ====================
  # Returns: { value, trend_percentage, trend_direction, sparkline_data, drill_down_url }
  def leads_count
    # Get leads for current period
    current_leads = @company.leads
      .where(created_at: @date_range[:start_date]..@date_range[:end_date])
    
    current_count = current_leads.count
    
    # Get leads for previous period
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    previous_count = @company.leads
      .where(created_at: previous_start..previous_end)
      .count
    
    # Calculate trend
    trend = calculate_trend(current_count, previous_count)
    
    # Generate sparkline (leads created per day, last 30 days)
    sparkline_data = generate_leads_sparkline
    
    {
      value: current_count,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      sparkline_data: sparkline_data,
      drill_down_url: '/crm/leads'
    }
  end

  # ==================== SERVICE TICKETS COUNT CARD ====================
  # Returns: { value, trend_percentage, trend_direction, sparkline_data, drill_down_url, by_status }
  def service_tickets_count
    # Get tickets for current period (exclude completed and cancelled)
    current_tickets = @company.service_tickets
      .where(created_at: @date_range[:start_date]..@date_range[:end_date])
      .where.not(status: ['completed', 'cancelled'])
    
    current_count = current_tickets.count
    
    # Get tickets for previous period
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    previous_count = @company.service_tickets
      .where(created_at: previous_start..previous_end)
      .where.not(status: ['completed', 'cancelled'])
      .count
    
    # Calculate trend
    trend = calculate_trend(current_count, previous_count)
    
    # Generate sparkline (tickets created per day, last 30 days)
    sparkline_data = generate_service_tickets_sparkline
    
    # Breakdown by status
    by_status = current_tickets.group(:status).count
    
    {
      value: current_count,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      sparkline_data: sparkline_data,
      drill_down_url: '/service',
      by_status: by_status
    }
  end

  # ==================== ACCOUNTS RECEIVABLE CARD ====================
  # Returns: { value, trend_percentage, trend_direction, sparkline_data, drill_down_url, formatted_value }
  def accounts_receivable
    # Get current A/R (all unpaid invoices)
    current_ar = @company.invoices
      .where.not(status: ['paid', 'cancelled'])
      .sum(:amount_due)
    
    # Get A/R from previous period (same time last month/year)
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_date = @date_range[:start_date] - previous_period_days.days
    
    previous_ar = @company.invoices
      .where('invoice_date < ?', previous_date)
      .where.not(status: ['paid', 'cancelled'])
      .sum(:amount_due)
    
    # Calculate trend
    trend = calculate_trend(current_ar, previous_ar)
    
    # Generate sparkline (last 30 days of A/R balance)
    sparkline_data = generate_ar_sparkline
    
    {
      value: current_ar,
      formatted_value: format_currency(current_ar),
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      sparkline_data: sparkline_data,
      drill_down_url: '/finance/invoices'
    }
  end

  # ==================== ACCOUNTS PAYABLE CARD ====================
  # Returns: { value, trend_percentage, trend_direction, sparkline_data, drill_down_url, formatted_value }
  def accounts_payable
    # Get current A/P (pending/processing payments)
    current_ap = @company.payments
      .where(status: ['pending', 'processing'])
      .sum(:amount)
    
    # Get A/P from previous period
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_date = @date_range[:start_date] - previous_period_days.days
    
    previous_ap = @company.payments
      .where('created_at < ?', previous_date)
      .where(status: ['pending', 'processing'])
      .sum(:amount)
    
    # Calculate trend
    trend = calculate_trend(current_ap, previous_ap)
    
    # Generate sparkline (last 30 days of A/P balance)
    sparkline_data = generate_ap_sparkline
    
    {
      value: current_ap,
      formatted_value: format_currency(current_ap),
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      sparkline_data: sparkline_data,
      drill_down_url: '/finance/payments'
    }
  end

  # ==================== PAYMENTS COUNT CARD ====================
  # Returns: { value, trend_percentage, trend_direction, sparkline_data, drill_down_url }
  def payments_count
    # Get completed payments for current period
    current_count = @company.payments
      .where(status: 'completed')
      .where(payment_date: @date_range[:start_date]..@date_range[:end_date])
      .count
    
    # Get payments for previous period
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    previous_count = @company.payments
      .where(status: 'completed')
      .where(payment_date: previous_start..previous_end)
      .count
    
    # Calculate trend
    trend = calculate_trend(current_count, previous_count)
    
    # Generate sparkline (payments per day, last 30 days)
    sparkline_data = generate_payments_sparkline
    
    {
      value: current_count,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      sparkline_data: sparkline_data,
      drill_down_url: '/finance/payments'
    }
  end

  # ==================== INVENTORY UNITS CARD ====================
  # Returns: { value, trend_percentage, trend_direction, sparkline_data, drill_down_url }
  def inventory_count
    # Get current inventory count (available vehicles)
    current_count = @company.vehicles
      .where(is_deleted: [false, nil])
      .where(status: 'available')
      .count
    
    # Get inventory from 30 days ago for trend
    previous_date = 30.days.ago
    
    # Count vehicles that were available 30 days ago
    # (created before then, and either still available or sold/reserved after that date)
    previous_count = @company.vehicles
      .where(is_deleted: [false, nil])
      .where('created_at <= ?', previous_date)
      .where(status: 'available')
      .count
    
    # Calculate trend
    trend = calculate_trend(current_count, previous_count)
    
    # Generate sparkline (inventory count per day, last 30 days)
    sparkline_data = generate_inventory_sparkline
    
    {
      value: current_count,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      sparkline_data: sparkline_data,
      drill_down_url: '/inventory'
    }
  end

  # ==================== A/R AGING CHART ====================
  # Returns: { buckets, total, drill_down_url }
  # Each bucket: { label, amount, count, percentage }
  def ar_aging_chart
    today = Date.today
    
    # Get all unpaid invoices
    unpaid_invoices = @company.invoices
      .where.not(status: ['paid', 'cancelled'])
      .select(:id, :invoice_date, :amount_due)
    
    # Categorize by aging buckets
    buckets = {
      current: { label: 'Current (0-30 days)', amount: 0, count: 0 },
      days_30: { label: '31-60 days', amount: 0, count: 0 },
      days_60: { label: '61-90 days', amount: 0, count: 0 },
      days_90: { label: '90+ days', amount: 0, count: 0 }
    }
    
    unpaid_invoices.each do |invoice|
      days_old = (today - invoice.invoice_date).to_i
      amount = (invoice.amount_due || 0).to_f

      if days_old <= 30
        buckets[:current][:amount] += amount
        buckets[:current][:count] += 1
      elsif days_old <= 60
        buckets[:days_30][:amount] += amount
        buckets[:days_30][:count] += 1
      elsif days_old <= 90
        buckets[:days_60][:amount] += amount
        buckets[:days_60][:count] += 1
      else
        buckets[:days_90][:amount] += amount
        buckets[:days_90][:count] += 1
      end
    end
    
    # Calculate total and percentages
    total_amount = buckets.values.sum { |b| b[:amount] }
    
    buckets_array = buckets.map do |key, bucket|
      percentage = total_amount > 0 ? (bucket[:amount] / total_amount * 100).round(1) : 0
      
      {
        key: key.to_s,
        label: bucket[:label],
        amount: bucket[:amount],
        formatted_amount: format_currency(bucket[:amount]),
        count: bucket[:count],
        percentage: percentage
      }
    end
    
    {
      buckets: buckets_array,
      total: total_amount,
      formatted_total: format_currency(total_amount),
      drill_down_url: '/finance/invoices'
    }
  end

  # ==================== PAYMENT METHODS BREAKDOWN ====================
  # Returns: { methods, total, drill_down_url }
  # Each method: { name, amount, count, percentage }
  def payment_methods_breakdown
    # Get all completed payments in date range
    payments = @company.payments
      .where(status: 'completed')
      .where(payment_date: @date_range[:start_date]..@date_range[:end_date])
    
    # Group by gateway_name (zego, stripe, manual)
    methods_data = payments.group(:gateway_name).select(
      "gateway_name, COUNT(*) as payment_count, SUM(amount) as total_sum"
    )
    
    total_amount = payments.sum(:amount)
    
    methods_array = methods_data.map do |method_data|
      # Access SQL results directly, not model methods
      method_total = method_data.read_attribute(:total_sum)
      method_count = method_data.read_attribute(:payment_count)
      method_name = method_data.gateway_name || 'Manual'
      
      percentage = total_amount > 0 ? (method_total / total_amount * 100).round(1) : 0
      
      {
        name: method_name.to_s.titleize,
        method_key: method_name,
        amount: method_total,
        formatted_amount: format_currency(method_total),
        count: method_count,
        percentage: percentage
      }
    end.sort_by { |m| -m[:amount] } # Sort by amount descending
    
    {
      methods: methods_array,
      total: total_amount,
      formatted_total: format_currency(total_amount),
      drill_down_url: '/finance/payments'
    }
  end

  # ==================== RECENT TRANSACTIONS ====================
  # Returns: { transactions, drill_down_url }
  # Each transaction: { id, date, amount, method, status, customer }
  def recent_transactions
    # Get recent completed payments (last 10)
    payments = @company.payments
      .where(status: 'completed')
      .order('payment_date DESC')
      .limit(10)
    
    transactions = payments.map do |payment|
      {
        id: payment.id,
        date: payment.payment_date,
        formatted_date: payment.payment_date.strftime('%b %d, %Y'),
        amount: payment.amount,
        formatted_amount: format_currency(payment.amount),
        method: payment.gateway_name&.titleize || 'Manual',
        status: payment.status,
        customer: payment.payer_name
      }
    end
    
    {
      transactions: transactions,
      drill_down_url: '/finance/payments'
    }
  end

  # ==================== PIPELINE FUNNEL CHART ====================
  # Returns: { stages, drill_down_url }
  # Each stage: { name, count, value, conversion_rate }
  def pipeline_funnel
    # Define standard deal stages in order
    stage_order = ['prospecting', 'qualification', 'needs_analysis', 'proposal', 'negotiation', 'closing']
    
    # Get all active deals grouped by stage
    deals_by_stage = @company.deals
      .where.not(stage: closed_stages)
      .group(:stage)
      .select('stage, COUNT(*) as count, SUM(value) as total_value')
    
    # Convert to hash for easier lookup
    stage_data = {}
    deals_by_stage.each do |record|
      stage_data[record.stage] = {
        count: record.count,
        value: record.total_value || 0
      }
    end
    
    # Build stages array in order
    stages = []
    total_deals = deals_by_stage.sum(&:count)
    
    stage_order.each_with_index do |stage, index|
      data = stage_data[stage] || { count: 0, value: 0 }
      
      # Calculate conversion rate (percentage of total deals)
      conversion_rate = total_deals > 0 ? (data[:count].to_f / total_deals * 100).round(1) : 0
      
      stages << {
        name: stage.titleize,
        stage_key: stage,
        count: data[:count],
        value: data[:value],
        formatted_value: format_currency(data[:value]),
        conversion_rate: conversion_rate,
        order: index
      }
    end
    
    {
      stages: stages,
      total_deals: total_deals,
      drill_down_url: '/deals'
    }
  end

  # ==================== REVENUE TREND CHART ====================
  # Returns: { months, drill_down_url }
  # Each month: { month, current_year, previous_year }
  def revenue_trend
    # Get last 12 months
    end_date = Date.today.end_of_month
    start_date = (end_date - 11.months).beginning_of_month
    
    # Get all payments for current year
    current_payments = @company.payments
      .where(status: 'completed')
      .where(payment_date: start_date..end_date)
      .select('payment_date, amount')
    
    # Get all payments for previous year
    previous_start = start_date - 1.year
    previous_end = end_date - 1.year
    previous_payments = @company.payments
      .where(status: 'completed')
      .where(payment_date: previous_start..previous_end)
      .select('payment_date, amount')
    
    # Group by month manually (database-agnostic)
    # Guard against nil/NaN amounts and ensure clean numeric output
    current_revenue = {}
    current_payments.each do |payment|
      next unless payment.payment_date.present?
      month_key = payment.payment_date.beginning_of_month
      current_revenue[month_key] ||= 0.0
      current_revenue[month_key] += (payment.amount || 0).to_f
    end
    
    previous_revenue = {}
    previous_payments.each do |payment|
      next unless payment.payment_date.present?
      month_key = payment.payment_date.beginning_of_month
      previous_revenue[month_key] ||= 0.0
      previous_revenue[month_key] += (payment.amount || 0).to_f
    end
    
    # Build months array
    months = []
    (start_date..end_date).select { |d| d.day == 1 }.each do |month_start|
      current = current_revenue[month_start] || 0
      previous = previous_revenue[month_start - 1.year] || 0
      
      months << {
        month: month_start.strftime('%b %Y'),
        month_short: month_start.strftime('%b'),
        current_year: current.to_f,
        previous_year: previous.to_f,
        current_formatted: format_currency(current),
        previous_formatted: format_currency(previous)
      }
    end
    
    {
      months: months,
      drill_down_url: '/finance/payments'
    }
  end

  # ==================== TOP PERFORMERS CHART ====================
  # Returns: { performers, metric, drill_down_url }
  # Each performer: { name, value, formatted_value }
  def top_performers
    Rails.logger.info "[Top Performers] Starting query for company #{@company.id}"
    
    # Get all closed won deals first
    closed_deals = @company.deals.where(stage: won_stages)
    Rails.logger.info "[Top Performers] Total closed_won deals: #{closed_deals.count}"
    
    if closed_deals.count == 0
      Rails.logger.info "[Top Performers] No closed won deals found"
      return {
        performers: [],
        metric: 'revenue',
        metric_label: 'Revenue',
        drill_down_url: '/deals'
      }
    end
    
    # Check available columns
    available_columns = @company.deals.column_names
    Rails.logger.info "[Top Performers] Deal columns: #{available_columns.join(', ')}"
    
    # Find owner field
    owner_field = ['assigned_to_id', 'owner_id', 'user_id', 'salesperson_id', 'created_by_id']
      .find { |field| available_columns.include?(field) }
    
    Rails.logger.info "[Top Performers] Using owner field: #{owner_field}"
    
    if owner_field.nil?
      Rails.logger.warn "[Top Performers] No owner field found"
      return {
        performers: [],
        metric: 'revenue',
        metric_label: 'Revenue',
        drill_down_url: '/deals'
      }
    end
    
    # Check how many deals have owners
    deals_with_owners = closed_deals.where.not(owner_field => nil).count
    Rails.logger.info "[Top Performers] Deals with #{owner_field}: #{deals_with_owners}"
    
    if deals_with_owners == 0
      Rails.logger.warn "[Top Performers] No deals have #{owner_field} assigned"
      return {
        performers: [],
        metric: 'revenue',
        metric_label: 'Revenue',
        drill_down_url: '/deals'
      }
    end
    
    # Simple aggregation query - don't filter by date for now.
    # Resolve won stages against the tenant's pipeline; safe against SQL injection
    # because stage keys are constrained to pipeline_stage_keys.
    won_list = won_stages.map { |s| ActiveRecord::Base.connection.quote(s) }.join(',')
    query = <<-SQL
      SELECT
        users.id as user_id,
        users.first_name,
        users.last_name,
        users.email,
        COUNT(deals.id) as deals_count,
        SUM(deals.value) as total_value
      FROM deals
      INNER JOIN users ON deals.#{owner_field} = users.id
        AND users.company_id = $1
      WHERE deals.company_id = $1
        AND deals.stage IN (#{won_list})
        AND deals.#{owner_field} IS NOT NULL
      GROUP BY users.id, users.first_name, users.last_name, users.email
      ORDER BY total_value DESC
      LIMIT 5
    SQL

    binds = [ActiveRecord::Relation::QueryAttribute.new('company_id', @company.id, ActiveRecord::Type::Integer.new)]
    results = ActiveRecord::Base.connection.exec_query(query, 'TopPerformers', binds)
    Rails.logger.info "[Top Performers] Query returned #{results.count} performers"
    
    performers = results.map do |row|
      name = "#{row['first_name']} #{row['last_name']}".strip
      name = row['email'] if name.blank?
      
      {
        user_id: row['user_id'],
        name: name,
        deals_count: row['deals_count'],
        value: row['total_value'] || 0,
        formatted_value: format_currency(row['total_value'] || 0)
      }
    end
    
    Rails.logger.info "[Top Performers] Returning #{performers.length} performers: #{performers.map { |p| p[:name] }.join(', ')}"
    
    {
      performers: performers,
      metric: 'revenue',
      metric_label: 'Revenue',
      drill_down_url: '/deals'
    }
  rescue StandardError => e
    Rails.logger.error "[Top Performers] Error: #{e.class.name} - #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    
    {
      performers: [],
      metric: 'revenue',
      metric_label: 'Revenue',
      drill_down_url: '/deals'
    }
  end

  # ==================== SERVICE STATUS CHART ====================
  # Returns: { statuses, total, drill_down_url }
  # Each status: { name, count, percentage }
  def service_status_chart
    # Get all service tickets grouped by status
    tickets_by_status = @company.service_tickets
      .where.not(status: 'cancelled')
      .group(:status)
      .count
    
    total = tickets_by_status.values.sum
    
    # Build statuses array
    statuses = tickets_by_status.map do |status, count|
      percentage = total > 0 ? (count.to_f / total * 100).round(1) : 0
      
      {
        name: status.titleize.gsub('_', ' '),
        status_key: status,
        count: count,
        percentage: percentage
      }
    end.sort_by { |s| -s[:count] } # Sort by count descending
    
    {
      statuses: statuses,
      total: total,
      drill_down_url: '/service'
    }
  end

  # ==================== RECENT ACTIVITY CARD ====================
  # Returns: { activities, drill_down_url }
  # Shows recently created/updated entities across modules
  def recent_activities
    Rails.logger.info "[Recent Activities] Starting for company #{@company.id}"
    activities = []
    
    # Get recent deals (NO DATE FILTER - show all recent)
    begin
      recent_deals = @company.deals
        .order('created_at DESC')
        .limit(5)
      
      Rails.logger.info "[Recent Activities] Found #{recent_deals.count} deals"
      
      recent_deals.each do |deal|
        # Use actual creator/owner name, NOT current user
        creator_name = deal.owner&.full_name || deal.user&.full_name || 'System'
        activities << {
          id: deal.id,
          type: 'deal',
          subject: deal.name || deal.customer_name || "Deal ##{deal.id}",
          entity_type: 'deal',
          entity_id: deal.id,
          entity_name: deal.name || deal.customer_name,
          user_name: creator_name,
          created_at: deal.created_at,
          formatted_time: time_ago_in_words(deal.created_at)
        }
      end
    rescue => e
      Rails.logger.error "[Recent Activities] Deals error: #{e.message}"
    end
    
    # Get recent tasks (NO DATE FILTER)
    begin
      if defined?(Task) && @company.respond_to?(:tasks)
        recent_tasks = @company.tasks
          .order('created_at DESC')
          .limit(5)
        
        Rails.logger.info "[Recent Activities] Found #{recent_tasks.count} tasks"
        
        recent_tasks.each do |task|
          # Use actual assigned user name, NOT current user
          task_user_name = task.assigned_to&.full_name || 'System'
          activities << {
            id: task.id,
            type: 'task',
            subject: task.title,
            entity_type: 'task',
            entity_id: task.id,
            entity_name: task.title,
            user_name: task_user_name,
            created_at: task.created_at,
            formatted_time: time_ago_in_words(task.created_at)
          }
        end
      else
        Rails.logger.info "[Recent Activities] Task model not available"
      end
    rescue => e
      Rails.logger.error "[Recent Activities] Tasks error: #{e.message}"
    end
    
    # Get recent service tickets (NO DATE FILTER)
    begin
      recent_tickets = @company.service_tickets
        .order('created_at DESC')
        .limit(5)
      
      Rails.logger.info "[Recent Activities] Found #{recent_tickets.count} tickets"
      
      recent_tickets.each do |ticket|
        # Use actual assigned technician name, NOT current user
        ticket_user = ticket.respond_to?(:technician) ? ticket.technician : nil
        ticket_user_name = ticket_user&.full_name || (ticket.assigned_to.present? ? @company.users.find_by(id: ticket.assigned_to)&.full_name : nil) || 'System'
        activities << {
          id: ticket.id,
          type: 'service_ticket',
          subject: ticket.title || "Ticket ##{ticket.id}",
          entity_type: 'service_ticket',
          entity_id: ticket.id,
          entity_name: ticket.title,
          user_name: ticket_user_name,
          created_at: ticket.created_at,
          formatted_time: time_ago_in_words(ticket.created_at)
        }
      end
    rescue => e
      Rails.logger.error "[Recent Activities] Tickets error: #{e.message}"
    end
    
    # Get recent brochures (NO DATE FILTER)
    begin
      if defined?(Brochure) && @company.respond_to?(:brochures)
        recent_brochures = @company.brochures
          .order('created_at DESC')
          .limit(3)
        
        Rails.logger.info "[Recent Activities] Found #{recent_brochures.count} brochures"
        
        recent_brochures.each do |brochure|
          # Use actual creator name if available, NOT current user
          brochure_user = brochure.respond_to?(:user) ? brochure.user : nil
          activities << {
            id: brochure.id,
            type: 'brochure',
            subject: brochure.title || "Brochure ##{brochure.id}",
            entity_type: 'brochure',
            entity_id: brochure.id,
            entity_name: brochure.title,
            user_name: brochure_user&.full_name || 'System',
            created_at: brochure.created_at,
            formatted_time: time_ago_in_words(brochure.created_at)
          }
        end
      else
        Rails.logger.info "[Recent Activities] Brochure model not available"
      end
    rescue => e
      Rails.logger.error "[Recent Activities] Brochures error: #{e.message}"
    end
    
    # Sort all activities by time and take top 10
    activities = activities.sort_by { |a| a[:created_at] }.reverse.take(10)
    
    Rails.logger.info "[Recent Activities] Returning #{activities.count} total activities"
    
    {
      activities: activities,
      drill_down_url: '/activities'
    }
  rescue StandardError => e
    Rails.logger.error "[Recent Activities] Fatal error: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    {
      activities: [],
      drill_down_url: '/activities'
    }
  end

  # ==================== PROJECT PHASE TASKS CARD ====================
  # Returns pending sub-tasks across all active projects for this company
  def project_phase_tasks
    items = []

    if defined?(ProjectPhaseTask)
      tasks = ProjectPhaseTask
        .joins(project_phase: { project: {} })
        .where(
          project_phase_tasks: { status: 'pending', company_id: @company.id },
          projects: { status: 'active', is_deleted: [false, nil] }
        )
        .includes(project_phase: :project)
        .order('projects.created_at DESC, project_phases.position ASC, project_phase_tasks.position ASC')
        .limit(20)

      items = tasks.map do |task|
        phase   = task.project_phase
        project = phase.project
        {
          id:            task.id,
          name:          task.name,
          phase_id:      phase.id,
          phase_name:    phase.name,
          phase_status:  phase.status,
          project_id:    project.id,
          project_name:  project.name,
          project_number: project.project_number,
          deal_id:       project.deal_id,
          is_required:   task.is_required
        }
      end
    end

    { tasks: items, total: items.size }
  rescue StandardError => e
    Rails.logger.error "[ProjectPhaseTasks] Error: #{e.message}"
    { tasks: [], total: 0 }
  end

  # ==================== UPCOMING TASKS CARD ====================
  # Returns: { tasks, drill_down_url }
  # Each task: { id, title, due_date, priority, assigned_to, entity_type, entity_id }
  def upcoming_tasks
    tasks_data = []
    
    # Get incomplete tasks - include overdue tasks
    if defined?(Task) && @company.respond_to?(:tasks)
      # Get all incomplete tasks (not just upcoming - include overdue)
      # Note: Database uses completed_at (datetime) not completed (boolean)
      tasks = @company.tasks
        .where(completed_at: nil)
        .where.not(due_date: nil)
        .order('due_date ASC')
        .limit(10)
      
      tasks_data = tasks.map do |task|
        assigned_user = task.respond_to?(:assigned_to) ? @company.users.find_by(id: task.assigned_to) : nil
        
        {
          id: task.id,
          title: task.title,
          due_date: task.due_date,
          formatted_due_date: task.due_date.strftime('%b %d'),
          priority: task.priority || 'medium',
          assigned_to: assigned_user ? "#{assigned_user.first_name} #{assigned_user.last_name}" : nil,
          entity_type: task.respond_to?(:taskable_type) ? task.taskable_type : nil,
          entity_id: task.respond_to?(:taskable_id) ? task.taskable_id : nil,
          overdue: task.due_date < Date.today
        }
      end
    end
    
    {
      tasks: tasks_data,
      drill_down_url: '/tasks'
    }
  rescue StandardError => e
    Rails.logger.error "[Upcoming Tasks] Error: #{e.message}"
    {
      tasks: [],
      drill_down_url: '/tasks'
    }
  end

  # ==================== UNREAD MESSAGES CARD ====================
  # Returns: { messages, total, drill_down_url }
  # Each message: { id, from, subject, preview, created_at }
  def unread_messages
    messages_data = []
    
    # Check if Message or Notification model exists
    if defined?(Notification)
      # CRITICAL: Must scope by company for tenant isolation
      # Without company scope, proxied users see notifications from ALL companies
      notifications = @company.notifications
        .where(recipient_id: @current_user.id, recipient_type: 'User')
        .where(read: [false, nil])
        .order('created_at DESC')
        .limit(10)
      
      messages_data = notifications.map do |notif|
        {
          id: notif.id,
          from: notif.respond_to?(:from_user) ? notif.from_user&.full_name : 'System',
          subject: notif.title || notif.message,
          preview: notif.message&.truncate(100),
          created_at: notif.created_at,
          formatted_time: time_ago_in_words(notif.created_at),
          priority: notif.respond_to?(:priority) ? notif.priority : 'normal'
        }
      end
    end
    
    {
      messages: messages_data,
      total: messages_data.count,
      drill_down_url: '/notifications'
    }
  rescue StandardError => e
    Rails.logger.error "[Unread Messages] Error: #{e.message}"
    {
      messages: [],
      total: 0,
      drill_down_url: '/notifications'
    }
  end

  # ==================== WEEK CALENDAR CARD ====================
  # Returns: { events, week_start, week_end }
  # Each event: { id, title, date, time, type, entity_type, entity_id }
  def week_calendar
    events_data = []
    
    # Get current week boundaries
    week_start = Date.today.beginning_of_week
    week_end = Date.today.end_of_week
    
    Rails.logger.info "[Week Calendar] Fetching events for week: #{week_start} to #{week_end}"
    
    # Get tasks due this week (using status enum, not completed_at)
    if defined?(Task) && @company.respond_to?(:tasks)
      # Task model uses status enum: pending, in_progress, on_hold, completed, cancelled
      tasks = @company.tasks
        .where.not(status: [:completed, :cancelled])
        .where(due_date: week_start..week_end)
        .order('due_date ASC, created_at ASC')
        .limit(50)
      
      Rails.logger.info "[Week Calendar] Found #{tasks.count} active tasks"
      
      tasks.each do |task|
        # Format time if available, otherwise show "All Day"
        time_str = if task.respond_to?(:due_time) && task.due_time.present?
          task.due_time.strftime('%I:%M %p')
        else
          'All Day'
        end
        
        events_data << {
          id: task.id,
          title: task.title,
          date: task.due_date.to_date.strftime('%Y-%m-%d'),  # Force YYYY-MM-DD format
          time: time_str,
          type: 'task',
          entity_type: task.taskable_type || 'Task',
          entity_id: task.taskable_id || task.id
        }
      end
    else
      Rails.logger.warn "[Week Calendar] Task model not available or company doesn't have tasks"
    end
    
    # Get service tickets scheduled this week
    service_tickets = @company.service_tickets
      .where(assigned_to: @current_user.id.to_s)
      .where.not(status: ['completed', 'cancelled'])
      .where(scheduled_date: week_start..week_end)
      .order('scheduled_date ASC')
      .limit(50)
    
    Rails.logger.info "[Week Calendar] Found #{service_tickets.count} scheduled service tickets"
    
    service_tickets.each do |ticket|
      events_data << {
        id: ticket.id,
        title: ticket.title || "Service Ticket ##{ticket.id}",
        date: ticket.scheduled_date.strftime('%Y-%m-%d'),
        time: 'All Day',  # Service tickets don't have specific times
        type: 'service_ticket',
        entity_type: 'ServiceTicket',
        entity_id: ticket.id
      }
    end
    
    Rails.logger.info "[Week Calendar] Returning #{events_data.count} total events"
    
    {
      events: events_data,
      week_start: week_start.to_s,
      week_end: week_end.to_s
    }
  rescue StandardError => e
    Rails.logger.error "[Week Calendar] Error: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    {
      events: [],
      week_start: Date.today.beginning_of_week.to_s,
      week_end: Date.today.end_of_week.to_s
    }
  end

  # ==================== QUICK ACTIONS CARD ====================
  # Returns: { actions }
  # Quick actions are permission-based and rendered on frontend
  # This endpoint can return empty data or custom actions
  def quick_actions
    {
      actions: []  # Frontend will use DEFAULT_ACTIONS based on permissions
    }
  end

  # ==================== MY SALES DASHBOARD CARDS ====================
  # These cards filter data to show only the current user's personal data

  # ==================== MY PIPELINE VALUE ====================
  def my_pipeline_value
    owner_field = find_owner_field
    return empty_metric_response if owner_field.nil?
    
    current_deals = @company.deals
      .where(owner_field => @current_user.id)
      .where.not(stage: closed_stages)
    
    current_value = current_deals.sum(:value) || 0
    
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    
    previous_value = @company.deals
      .where(owner_field => @current_user.id)
      .where(created_at: previous_start..previous_end)
      .where.not(stage: closed_stages)
      .sum(:value) || 0
    
    trend = calculate_trend(current_value, previous_value)
    sparkline_data = generate_my_pipeline_sparkline(owner_field)
    
    {
      value: current_value,
      formatted_value: format_currency(current_value),
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      sparkline_data: sparkline_data,
      drill_down_url: '/deals?assigned_to_me=true'
    }
  end

  # ==================== MY CLOSED DEALS THIS MONTH ====================
  def my_closed_deals
    owner_field = find_owner_field
    return empty_metric_response if owner_field.nil?
    
    current_month_start = Date.today.beginning_of_month
    current_month_end = Date.today.end_of_month
    
    current_deals = @company.deals
      .where(owner_field => @current_user.id)
      .where(stage: won_stages)
      .where(updated_at: current_month_start..current_month_end)
    
    current_value = current_deals.sum(:value) || 0
    current_count = current_deals.count
    
    previous_month_start = (Date.today - 1.month).beginning_of_month
    previous_month_end = (Date.today - 1.month).end_of_month
    
    previous_value = @company.deals
      .where(owner_field => @current_user.id)
      .where(stage: won_stages)
      .where(updated_at: previous_month_start..previous_month_end)
      .sum(:value) || 0
    
    trend = calculate_trend(current_value, previous_value)
    sparkline_data = generate_my_closed_deals_sparkline(owner_field)
    
    {
      value: current_value,
      formatted_value: format_currency(current_value),
      count: current_count,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      sparkline_data: sparkline_data,
      drill_down_url: "/deals?assigned_to_me=true&stage=#{won_stages.join(',')}"
    }
  end

  # ==================== MY ACTIVITY COUNT ====================
  # Aggregates activities across all entity types (deals, leads, contacts, accounts, locations)
  # Returns: { value, trend_percentage, trend_direction, drill_down_url }
  def my_activity_count
    current_count = 0
    previous_count = 0
    
    # Calculate date ranges
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    
    # Count activities from all entity types
    activity_models = [
      { model: DealActivity, company_join: :deal },
      { model: LeadActivity, company_join: :lead },
      { model: ContactActivity, company_join: :contact },
      { model: AccountActivity, company_join: :account },
      { model: LocationActivity, company_join: :location }
    ]
    
    activity_models.each do |config|
      model = config[:model]
      next unless defined?(model)
      
      begin
        # Check if model has assigned_to_id column
        has_assigned_to = model.column_names.include?('assigned_to_id')
        
        # Build where clause based on available columns
        if has_assigned_to
          # Activities where user is either creator OR assignee
          where_clause = model.arel_table[:user_id].eq(@current_user.id)
            .or(model.arel_table[:assigned_to_id].eq(@current_user.id))
        else
          # Activities where user is only the creator
          where_clause = model.arel_table[:user_id].eq(@current_user.id)
        end
        
        # Current period count
        current_count += model
          .joins(config[:company_join])
          .where("#{config[:company_join].to_s.pluralize}.company_id = ?", @company.id)
          .where(created_at: @date_range[:start_date]..@date_range[:end_date])
          .where(where_clause)
          .count
        
        # Previous period count
        previous_count += model
          .joins(config[:company_join])
          .where("#{config[:company_join].to_s.pluralize}.company_id = ?", @company.id)
          .where(created_at: previous_start..previous_end)
          .where(where_clause)
          .count
          
        Rails.logger.info "[My Activity Count] #{model.name}: #{current_count} activities"
      rescue StandardError => model_error
        Rails.logger.error "[My Activity Count] Error with #{model.name}: #{model_error.message}"
        # Continue to next model instead of failing entirely
      end
    end
    
    Rails.logger.info "[My Activity Count] User #{@current_user.id}: #{current_count} current, #{previous_count} previous"
    
    trend = calculate_trend(current_count, previous_count)
    
    {
      value: current_count,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      drill_down_url: '/tasks?assigned_to_me=true'  # Link to user's tasks
    }
  rescue StandardError => e
    Rails.logger.error "[My Activity Count] Fatal error: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    
    {
      value: 0,
      trend_percentage: 0,
      trend_direction: 'neutral',
      drill_down_url: '/tasks?assigned_to_me=true'
    }
  end

  # ==================== MY PIPELINE FUNNEL ====================
  def my_pipeline_funnel
    owner_field = find_owner_field
    return { stages: [], drill_down_url: '/deals' } if owner_field.nil?
    
    stage_order = ['prospecting', 'qualification', 'needs_analysis', 'proposal', 'negotiation', 'closing']
    
    deals_by_stage = @company.deals
      .where(owner_field => @current_user.id)
      .where.not(stage: closed_stages)
      .group(:stage)
      .select('stage, COUNT(*) as count, SUM(value) as total_value')
    
    stage_data = {}
    deals_by_stage.each do |record|
      stage_data[record.stage] = {
        count: record.count,
        value: record.total_value || 0
      }
    end
    
    stages = []
    total_deals = deals_by_stage.sum(&:count)
    
    stage_order.each_with_index do |stage, index|
      data = stage_data[stage] || { count: 0, value: 0 }
      conversion_rate = total_deals > 0 ? (data[:count].to_f / total_deals * 100).round(1) : 0
      
      stages << {
        name: stage.titleize,
        stage_key: stage,
        count: data[:count],
        value: data[:value],
        formatted_value: format_currency(data[:value]),
        conversion_rate: conversion_rate,
        order: index
      }
    end
    
    {
      stages: stages,
      total_deals: total_deals,
      drill_down_url: '/deals?assigned_to_me=true'
    }
  end

  # ==================== MY RECENT ACTIVITIES ====================
  def my_recent_activities
    activities = []
    
    # Activity models with their entity associations
    activity_models = [
      { model: DealActivity, entity_type: 'deal', company_join: :deal },
      { model: LeadActivity, entity_type: 'lead', company_join: :lead },
      { model: ContactActivity, entity_type: 'contact', company_join: :contact },
      { model: AccountActivity, entity_type: 'account', company_join: :account }
    ]
    
    activity_models.each do |config|
      model = config[:model]
      next unless defined?(model)
      
      begin
        # Get recent activities from this entity type
        entity_activities = model
          .joins(config[:company_join])
          .where("#{config[:company_join].to_s.pluralize}.company_id = ?", @company.id)
          .where(user_id: @current_user.id)
          .order('created_at DESC')
          .limit(10)
        
        # Transform to common format
        entity_activities.each do |activity|
          entity = activity.send(config[:company_join])
          
          activities << {
            id: activity.id,
            type: activity.activity_type,
            subject: activity.subject || activity.notes&.truncate(50),
            entity_type: config[:entity_type],
            entity_id: entity.id,
            entity_name: get_entity_name(entity, config[:entity_type]),
            user_name: activity.user&.full_name || 'Unknown',
            created_at: activity.created_at,
            formatted_time: time_ago_in_words(activity.created_at)
          }
        end
      rescue StandardError => model_error
        Rails.logger.error "[My Recent Activities] Error with #{model.name}: #{model_error.message}"
      end
    end
    
    # Sort all activities by created_at DESC and limit to 10 most recent
    activities.sort_by! { |a| a[:created_at] }
    activities.reverse!
    activities = activities.first(10)
    
    {
      activities: activities,
      drill_down_url: '/tasks'
    }
  end
  
  # Helper to get entity display name
  def get_entity_name(entity, entity_type)
    case entity_type
    when 'deal'
      entity.name || entity.customer_name || "Deal ##{entity.id}"
    when 'lead'
      "#{entity.first_name} #{entity.last_name}".strip.presence || "Lead ##{entity.id}"
    when 'contact'
      entity.full_name || "Contact ##{entity.id}"
    when 'account'
      entity.name || "Account ##{entity.id}"
    else
      "#{entity_type.titleize} ##{entity.id}"
    end
  end

  # ==================== MY TASKS ====================
  def my_tasks
    tasks_data = []
    
    # Activity models with their entity associations
    activity_models = [
      { model: DealActivity, entity_type: 'deal', company_join: :deal },
      { model: LeadActivity, entity_type: 'lead', company_join: :lead },
      { model: ContactActivity, entity_type: 'contact', company_join: :contact },
      { model: AccountActivity, entity_type: 'account', company_join: :account }
    ]
    
    activity_models.each do |config|
      model = config[:model]
      next unless defined?(model)
      
      begin
        # Check if model has assigned_to_id column
        has_assigned_to = model.column_names.include?('assigned_to_id')
        
        # Build where clause for assignment
        if has_assigned_to
          where_clause = model.arel_table[:user_id].eq(@current_user.id)
            .or(model.arel_table[:assigned_to_id].eq(@current_user.id))
        else
          where_clause = model.arel_table[:user_id].eq(@current_user.id)
        end
        
        # Get upcoming and overdue tasks (activity_type = 'task', not completed)
        tasks = model
          .joins(config[:company_join])
          .where("#{config[:company_join].to_s.pluralize}.company_id = ?", @company.id)
          .where(activity_type: 'task')
          .where(where_clause)
          .where.not(due_date: nil)
          .where('completed_at IS NULL')
          .order('due_date ASC')
          .limit(10)
        
        # Transform to common format
        tasks.each do |task|
          entity = task.send(config[:company_join])
          
          tasks_data << {
            id: task.id,
            title: task.subject || 'Untitled Task',
            due_date: task.due_date,
            formatted_due_date: task.due_date.strftime('%b %d'),
            priority: task.priority || 'medium',
            entity_type: config[:entity_type],
            entity_id: entity.id,
            entity_name: get_entity_name(entity, config[:entity_type]),
            overdue: task.due_date < Date.today
          }
        end
      rescue StandardError => model_error
        Rails.logger.error "[My Tasks] Error with #{model.name}: #{model_error.message}"
      end
    end
    
    # Sort by due_date ASC and limit to 10 most urgent
    tasks_data.sort_by! { |t| t[:due_date] }
    tasks_data = tasks_data.first(10)
    
    {
      tasks: tasks_data,
      drill_down_url: '/tasks?assigned_to_me=true'
    }
  end

  # ==================== MY CALENDAR ====================
  def my_calendar
    events_data = []
    today = Date.today
    
    # Activity models with their entity associations
    activity_models = [
      { model: DealActivity, entity_type: 'deal', company_join: :deal },
      { model: LeadActivity, entity_type: 'lead', company_join: :lead },
      { model: ContactActivity, entity_type: 'contact', company_join: :contact },
      { model: AccountActivity, entity_type: 'account', company_join: :account }
    ]
    
    activity_models.each do |config|
      model = config[:model]
      next unless defined?(model)
      
      begin
        # Check if model has assigned_to_id column
        has_assigned_to = model.column_names.include?('assigned_to_id')
        
        # Build where clause for assignment
        if has_assigned_to
          where_clause = model.arel_table[:user_id].eq(@current_user.id)
            .or(model.arel_table[:assigned_to_id].eq(@current_user.id))
        else
          where_clause = model.arel_table[:user_id].eq(@current_user.id)
        end
        
        # Get today's events (tasks and meetings due today)
        activities = model
          .joins(config[:company_join])
          .where("#{config[:company_join].to_s.pluralize}.company_id = ?", @company.id)
          .where(activity_type: ['task', 'meeting'])
          .where(where_clause)
          .where('DATE(due_date) = ?', today)
          .where('completed_at IS NULL')
          .order('due_date ASC')
        
        # Transform to common format
        activities.each do |activity|
          entity = activity.send(config[:company_join])
          
          # Extract time from due_date timestamp
          time_str = if activity.due_date.present?
            activity.due_date.strftime('%I:%M %p')
          else
            'All Day'
          end
          
          events_data << {
            id: activity.id,
            title: activity.subject || 'Untitled Event',
            date: activity.due_date.to_date.to_s,  # Add date field for each event
            time: time_str,
            type: activity.activity_type,
            entity_type: config[:entity_type],
            entity_id: entity.id,
            entity_name: get_entity_name(entity, config[:entity_type])
          }
        end
      rescue StandardError => model_error
        Rails.logger.error "[My Calendar] Error with #{model.name}: #{model_error.message}"
      end
    end
    
    # Sort by time (All Day events first, then by time)
    events_data.sort_by! { |e| e[:time] == 'All Day' ? '00:00 AM' : e[:time] }
    
    {
      events: events_data,
      date: today.to_s,
      formatted_date: today.strftime('%A, %B %d'),
      drill_down_url: '/tasks?assigned_to_me=true&date=' + today.to_s
    }
  end

  # ==================== MY RECENT DEALS ====================
  def my_recent_deals
    deals_data = []
    owner_field = find_owner_field
    
    if owner_field
      recent_deals = @company.deals
        .where(owner_field => @current_user.id)
        .order('updated_at DESC')
        .limit(10)
      
      deals_data = recent_deals.map do |deal|
        {
          id: deal.id,
          title: deal.name || deal.customer_name || "Deal ##{deal.id}",
          stage: deal.stage&.titleize || 'Unknown',
          value: deal.value || 0,
          expected_close_date: deal.respond_to?(:expected_close_date) ? deal.expected_close_date : deal.updated_at,
          owner_name: @current_user.full_name,
          company_name: deal.customer_name,
          probability: deal.respond_to?(:probability) ? deal.probability : nil
        }
      end
    end
    
    {
      deals: deals_data,
      drill_down_url: '/deals?assigned_to_me=true'
    }
  end

  # Helper methods for My Sales cards
  def find_owner_field
    return @owner_field if defined?(@owner_field)
    available_columns = @company.deals.column_names
    @owner_field = ['assigned_to_id', 'owner_id', 'user_id', 'salesperson_id', 'created_by_id']
      .find { |field| available_columns.include?(field) }
  end

  def empty_metric_response
    {
      value: 0,
      formatted_value: format_currency(0),
      trend_percentage: 0,
      trend_direction: 'neutral',
      sparkline_data: generate_empty_sparkline,
      drill_down_url: '/deals'
    }
  end

  def generate_my_pipeline_sparkline(owner_field)
    end_date = @date_range[:end_date]
    start_date = end_date - 29.days
    
    sparkline = []
    (start_date..end_date).each do |date|
      value = @company.deals
        .where(owner_field => @current_user.id)
        .where('created_at <= ?', date)
        .where.not(stage: closed_stages)
        .sum(:value) || 0
      
      sparkline << {
        date: date.strftime('%Y-%m-%d'),
        value: value
      }
    end
    
    sparkline
  end

  def generate_my_closed_deals_sparkline(owner_field)
    current_month_start = Date.today.beginning_of_month
    current_month_end = Date.today.end_of_month
    
    sparkline = []
    (current_month_start..current_month_end).each do |date|
      count = @company.deals
        .where(owner_field => @current_user.id)
        .where(stage: won_stages)
        .where('DATE(updated_at) = ?', date)
        .count
      
      sparkline << {
        date: date.strftime('%Y-%m-%d'),
        value: count
      }
    end
    
    sparkline
  end

  # ==================== MY SERVICE DASHBOARD CARDS ====================
  # Personal service technician dashboard cards

  # ==================== MY OPEN TICKETS ====================
  def my_open_tickets
    # Get tickets assigned to current user with status='open'
    current_tickets = @company.service_tickets
      .where(assigned_to: @current_user.id.to_s)
      .where(status: 'open')  # Only 'open' status, not all non-completed
    
    current_count = current_tickets.count
    
    # Get count from previous period for trend
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    
    previous_count = @company.service_tickets
      .where(assigned_to: @current_user.id.to_s)
      .where(created_at: previous_start..previous_end)
      .where(status: 'open')
      .count
    
    trend = calculate_trend(current_count, previous_count)
    
    {
      value: current_count,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      drill_down_url: '/service?assigned_to_me=true&status=open'
    }
  end

  # ==================== TODAY TICKETS ====================
  def today_tickets
    # Get tickets assigned to current user that are scheduled today
    today = Date.today
    
    current_count = @company.service_tickets
      .where(assigned_to: @current_user.id.to_s)
      .where(scheduled_date: today)
      .where.not(status: ['completed', 'cancelled'])
      .count
    
    # Get yesterday's count for trend
    yesterday = Date.yesterday
    previous_count = @company.service_tickets
      .where(assigned_to: @current_user.id.to_s)
      .where(scheduled_date: yesterday)
      .where.not(status: ['completed', 'cancelled'])
      .count
    
    trend = calculate_trend(current_count, previous_count)
    
    {
      value: current_count,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      drill_down_url: '/service?assigned_to_me=true&due=today'
    }
  end

  # ==================== OVERDUE TICKETS ====================
  def overdue_tickets
    # Get tickets assigned to current user that are overdue
    today = Date.today
    
    current_count = @company.service_tickets
      .where(assigned_to: @current_user.id.to_s)
      .where('scheduled_date < ?', today)
      .where.not(status: ['completed', 'cancelled'])
      .count
    
    # Get count from a week ago for trend
    week_ago = 7.days.ago.to_date
    previous_count = @company.service_tickets
      .where(assigned_to: @current_user.id.to_s)
      .where('scheduled_date < ?', week_ago)
      .where.not(status: ['completed', 'cancelled'])
      .count
    
    trend = calculate_trend(current_count, previous_count)
    
    {
      value: current_count,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      drill_down_url: '/service?assigned_to_me=true&status=overdue'
    }
  end

  # ==================== COMPLETED TICKETS ====================
  def completed_tickets
    # Get tickets assigned to current user completed in date range (use updated_at as proxy for completion)
    current_count = @company.service_tickets
      .where(assigned_to: @current_user.id.to_s)
      .where(status: 'completed')
      .where(updated_at: @date_range[:start_date]..@date_range[:end_date])
      .count
    
    # Get count from previous period for trend
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    
    previous_count = @company.service_tickets
      .where(assigned_to: @current_user.id.to_s)
      .where(status: 'completed')
      .where(updated_at: previous_start..previous_end)
      .count
    
    trend = calculate_trend(current_count, previous_count)
    
    {
      value: current_count,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      drill_down_url: '/service?assigned_to_me=true&status=completed'
    }
  end

  # ==================== PRIORITY TICKET LIST ====================
  def priority_ticket_list
    # Get high priority tickets assigned to current user
    tickets = @company.service_tickets
      .where(assigned_to: @current_user.id.to_s)
      .where.not(status: ['completed', 'cancelled'])
      .where(priority: ['high', 'urgent'])
      .order('scheduled_date ASC NULLS LAST, created_at ASC')
      .limit(10)
    
    tickets_data = tickets.map do |ticket|
      # Get customer name from contact or account
      customer_name = if ticket.contact.present?
        ticket.contact.full_name
      elsif ticket.account.present?
        ticket.account.name
      else
        'N/A'
      end
      
      {
        id: ticket.id,
        title: ticket.title || "Ticket ##{ticket.id}",
        priority: ticket.priority,
        status: ticket.status,
        due_date: ticket.scheduled_date,
        formatted_due_date: ticket.scheduled_date ? ticket.scheduled_date.strftime('%b %d') : 'No due date',
        customer_name: customer_name,
        overdue: ticket.scheduled_date && ticket.scheduled_date < Date.today
      }
    end
    
    {
      tickets: tickets_data,
      drill_down_url: '/service?assigned_to_me=true&priority=high'
    }
  end

  # ==================== RECENT COMPLETIONS ====================
  def recent_completions
    # Get recently completed tickets assigned to current user (use updated_at as proxy for completion)
    tickets = @company.service_tickets
      .where(assigned_to: @current_user.id.to_s)
      .where(status: 'completed')
      .order('updated_at DESC')
      .limit(10)
    
    tickets_data = tickets.map do |ticket|
      # Get customer name from contact or account
      customer_name = if ticket.contact.present?
        ticket.contact.full_name
      elsif ticket.account.present?
        ticket.account.name
      else
        'N/A'
      end
      
      {
        id: ticket.id,
        title: ticket.title || "Ticket ##{ticket.id}",
        completed_at: ticket.updated_at,
        formatted_completed_at: ticket.updated_at.strftime('%b %d, %I:%M %p'),
        customer_name: customer_name,
        resolution: ticket.notes&.truncate(100) || 'No notes'
      }
    end
    
    {
      tickets: tickets_data,
      drill_down_url: '/service?assigned_to_me=true&status=completed'
    }
  end

  # ============================================================
  # GM OVERVIEW CARDS
  # ============================================================

  # ==================== LEAD CONVERSION FUNNEL ====================
  def lead_conversion_funnel
    stage_keys = %w[new contacted qualified proposal converted lost]
    range = @date_range[:start_date]..@date_range[:end_date]

    leads_in_range = @company.leads.where(created_at: range)
    leads_in_range = leads_in_range.where(location_id: Current.location_id) if location_filtered?

    counts = leads_in_range.group(:status).count
    total  = counts.values.sum
    converted_count = counts['converted'].to_i

    stages = stage_keys.map do |key|
      count = counts[key].to_i
      pct   = total.positive? ? (count.to_f / total * 100).round(1) : 0.0
      { name: key.titleize, stage_key: key, count: count, percentage: pct }
    end

    conversion_rate = total.positive? ? (converted_count.to_f / total * 100).round(1) : 0.0

    prev_range = previous_period_range
    prev_leads = @company.leads.where(created_at: prev_range)
    prev_leads = prev_leads.where(location_id: Current.location_id) if location_filtered?
    prev_total     = prev_leads.count
    prev_converted = prev_leads.where(status: 'converted').count
    prev_rate      = prev_total.positive? ? (prev_converted.to_f / prev_total * 100).round(1) : 0.0
    trend          = calculate_trend(conversion_rate, prev_rate)

    {
      stages: stages,
      conversion_rate: conversion_rate,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      total_leads: total,
      drill_down_url: '/crm/leads'
    }
  end

  # ==================== LEAD VELOCITY ====================
  def lead_velocity
    weeks = []
    end_date = Date.today.end_of_week

    8.times do |i|
      week_start = (end_date - (i * 7).days).beginning_of_week
      week_end   = week_start.end_of_week
      scope = @company.leads.where(created_at: week_start.beginning_of_day..week_end.end_of_day)
      scope = scope.where(location_id: Current.location_id) if location_filtered?
      weeks.unshift(week_label: week_start.strftime('%b %d'), week_start: week_start, count: scope.count)
    end

    current_week  = weeks.last[:count]
    previous_week = weeks[-2] ? weeks[-2][:count] : 0
    trend         = calculate_trend(current_week, previous_week)
    total         = weeks.sum { |w| w[:count] }
    avg_per_week  = weeks.any? ? (total.to_f / weeks.size).round(1) : 0.0

    {
      weeks: weeks.map { |w| { week_label: w[:week_label], week_start: w[:week_start].to_s, count: w[:count] } },
      current_week: current_week,
      previous_week: previous_week,
      total: total,
      avg_per_week: avg_per_week,
      change_percentage: trend[:percentage],
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      drill_down_url: '/crm/leads'
    }
  end

  # ==================== ACCOUNT GROWTH ====================
  def account_growth
    range      = @date_range[:start_date]..@date_range[:end_date]
    prev_range = previous_period_range

    new_scope  = @company.accounts.where(created_at: range)
    prev_scope = @company.accounts.where(created_at: prev_range)
    if location_filtered? && @company.accounts.column_names.include?('location_id')
      new_scope  = new_scope.where(location_id: Current.location_id)
      prev_scope = prev_scope.where(location_id: Current.location_id)
    end

    new_accounts          = new_scope.count
    previous_new_accounts = prev_scope.count
    trend                 = calculate_trend(new_accounts, previous_new_accounts)

    total_accounts = @company.accounts.count

    active_account_ids  = @company.deals.where('deals.updated_at >= ?', 90.days.ago).where.not(account_id: nil).distinct.pluck(:account_id)
    active_account_ids += @company.invoices.where('invoices.created_at >= ?', 90.days.ago).joins('LEFT JOIN deals ON deals.id = invoices.deal_id').where.not('deals.account_id' => nil).pluck('deals.account_id')
    active_accounts = active_account_ids.uniq.count

    active_rate = total_accounts.positive? ? (active_accounts.to_f / total_accounts * 100).round(1) : 0.0

    {
      new_accounts: new_accounts,
      previous_new_accounts: previous_new_accounts,
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      active_accounts: active_accounts,
      total_accounts: total_accounts,
      active_rate: active_rate,
      drill_down_url: '/crm/accounts'
    }
  end

  # ==================== SALES VELOCITY ====================
  def sales_velocity
    range = @date_range[:start_date].to_time..@date_range[:end_date].to_time.end_of_day

    closed_deals = @company.deals.where(deleted_at: nil)
    closed_deals = closed_deals.where(location_id: Current.location_id) if location_filtered?

    won = closed_deals.where(stage: won_stages).where(won_at: range)
    lost = closed_deals.where(stage: lost_stages).where(lost_at: range)

    won_count  = won.count
    lost_count = lost.count

    cycle_seconds_avg = won.where.not(won_at: nil)
                          .pluck(Arel.sql('EXTRACT(EPOCH FROM (won_at - created_at))'))
                          .compact
    avg_cycle_days = cycle_seconds_avg.any? ? (cycle_seconds_avg.sum / cycle_seconds_avg.size / 86_400.0).round(1) : 0.0

    avg_deal_value = won_count.positive? ? (won.sum(:value).to_f / won_count).round(2) : 0.0
    win_rate       = (won_count + lost_count).positive? ? (won_count.to_f / (won_count + lost_count) * 100).round(1) : 0.0

    pipeline_scope = @company.deals.where(deleted_at: nil).where.not(stage: closed_stages)
    pipeline_scope = pipeline_scope.where(location_id: Current.location_id) if location_filtered?
    total_pipeline_value = pipeline_scope.sum(:value).to_f

    {
      avg_cycle_days: avg_cycle_days,
      avg_deal_value: avg_deal_value,
      formatted_avg_deal_value: format_currency(avg_deal_value),
      win_rate: win_rate,
      deals_closed: won_count,
      deals_lost: lost_count,
      total_pipeline_value: total_pipeline_value,
      formatted_pipeline_value: format_currency(total_pipeline_value),
      drill_down_url: '/deals'
    }
  end

  # ==================== PROJECT VELOCITY ====================
  def project_velocity
    range = @date_range[:start_date].to_time..@date_range[:end_date].to_time.end_of_day

    projects_scope = @company.projects.where(is_deleted: [false, nil])
    projects_scope = projects_scope.where(location_id: Current.location_id) if location_filtered?

    active_scope = projects_scope.where(status: 'active')
    active_count = active_scope.count

    by_phase = ProjectPhase.joins('INNER JOIN projects ON projects.current_phase_id = project_phases.id')
                           .where(projects: { id: active_scope.pluck(:id) })
                           .group('project_phases.name')
                           .count
                           .map { |name, count| { phase_name: name, count: count } }

    avg_pairs = ProjectPhase.where(company_id: @company.id, status: 'completed')
                            .where.not(started_at: nil, completed_at: nil)
                            .group(:name)
                            .pluck(:name, Arel.sql('AVG(EXTRACT(EPOCH FROM (completed_at - started_at)) / 86400.0)'))

    avg_days_per_phase = avg_pairs.map { |name, avg| { phase_name: name, avg_days: avg.to_f.round(1) } }

    completed_count = projects_scope.where(status: 'completed').where(actual_completion_date: @date_range[:start_date]..@date_range[:end_date]).count

    {
      by_phase: by_phase,
      avg_days_per_phase: avg_days_per_phase,
      completed_count: completed_count,
      active_count: active_count,
      drill_down_url: '/projects'
    }
  end

  # ==================== BUSINESS HEALTH SUMMARY ====================
  def business_health_summary
    # Revenue trend
    current_rev   = calculate_revenue(@date_range[:start_date], @date_range[:end_date])
    prev_range    = previous_period_range
    previous_rev  = calculate_revenue(prev_range.first, prev_range.last)
    rev_trend     = calculate_trend(current_rev, previous_rev)
    rev_status    = case rev_trend[:direction]
                    when 'up'   then 'green'
                    when 'down' then 'red'
                    else 'yellow'
                    end

    # Lead trend
    leads_current  = @company.leads.where(created_at: @date_range[:start_date]..@date_range[:end_date]).count
    leads_previous = @company.leads.where(created_at: prev_range).count
    lead_trend     = calculate_trend(leads_current, leads_previous)
    lead_status    = case lead_trend[:direction]
                     when 'up'   then 'green'
                     when 'down' then 'red'
                     else 'yellow'
                     end

    # Win rate
    range = @date_range[:start_date].to_time..@date_range[:end_date].to_time.end_of_day
    # won_at/lost_at aren't reliably set on every won/lost deal (esp. tenants
    # with custom pipelines), so fall back to updated_at for range filtering.
    won_count  = @company.deals.where(stage: won_stages)
                                .where('COALESCE(won_at, updated_at) BETWEEN ? AND ?', range.first, range.last).count
    lost_count = @company.deals.where(stage: lost_stages)
                                .where('COALESCE(lost_at, updated_at) BETWEEN ? AND ?', range.first, range.last).count
    win_rate   = (won_count + lost_count).positive? ? (won_count.to_f / (won_count + lost_count) * 100).round(1) : 0.0
    win_status = if win_rate > 30 then 'green'
                 elsif win_rate >= 15 then 'yellow'
                 else 'red'
                 end

    # Overdue invoices
    overdue_count = @company.invoices.where(is_deleted: [false, nil], status: 'sent').where('due_date < ?', Date.current).count
    overdue_status = if overdue_count > 10 then 'red'
                     elsif overdue_count >= 3 then 'yellow'
                     else 'green'
                     end

    # Active projects
    active_projects = @company.projects.where(is_deleted: [false, nil], status: 'active').count

    {
      indicators: [
        { name: 'revenue',          status: rev_status,     value: current_rev,      label: "#{rev_trend[:direction] == 'up' ? '+' : ''}#{rev_trend[:percentage]}% vs prev" },
        { name: 'lead_flow',        status: lead_status,    value: leads_current,    label: "#{leads_current} new leads" },
        { name: 'win_rate',         status: win_status,     value: win_rate,         label: "#{win_rate}% win rate" },
        { name: 'overdue_invoices', status: overdue_status, value: overdue_count,    label: "#{overdue_count} overdue" },
        { name: 'active_projects',  status: 'green',        value: active_projects,  label: "#{active_projects} active" }
      ]
    }
  end

  # ============================================================
  # SALES MANAGER CARDS
  # ============================================================

  # ==================== REP LEADERBOARD ====================
  def rep_leaderboard
    owner_field = find_dashboard_owner_field
    return { reps: [] } unless owner_field

    range = @date_range[:start_date].to_time..@date_range[:end_date].to_time.end_of_day

    deals_scope = @company.deals.where(deleted_at: nil)
    deals_scope = deals_scope.where(location_id: Current.location_id) if location_filtered?

    user_ids = deals_scope.where.not(owner_field => nil).distinct.pluck(owner_field)
    return { reps: [] } if user_ids.empty?

    users = User.where(id: user_ids, company_id: @company.id, status: 'active')

    rep_rows = users.map do |user|
      user_deals = deals_scope.where(owner_field => user.id)

      closed_won_scope = user_deals.where(stage: won_stages)
                                    .where('COALESCE(won_at, updated_at) BETWEEN ? AND ?', range.first, range.last)
      closed_count = closed_won_scope.count
      closed_value = closed_won_scope.sum(:value).to_f

      pipeline_scope = user_deals.where.not(stage: closed_stages)
      pipeline_count = pipeline_scope.count
      pipeline_value = pipeline_scope.sum(:value).to_f

      activities = LeadActivity.joins(:lead)
                               .where(leads: { company_id: @company.id })
                               .where(user_id: user.id)
                               .where(activity_type: %w[call meeting email email_sent sms])
                               .where(created_at: range)
                               .count

      lead_total     = @company.leads.where(owner_id: user.id).where(created_at: range).count
      lead_converted = @company.leads.where(owner_id: user.id, status: 'converted').where(created_at: range).count
      conversion_rate = lead_total.positive? ? (lead_converted.to_f / lead_total * 100).round(1) : 0.0

      full_name = [user.first_name, user.last_name].compact.join(' ').presence || user.name.presence || user.email
      # Split for the frontend, which formats "First L." itself. Fall back to the
      # full name in first_name if we couldn't split it (e.g. email-only users).
      first_name, last_name =
        if user.first_name.present? || user.last_name.present?
          [user.first_name.to_s, user.last_name.to_s]
        else
          [full_name, '']
        end
      {
        user_id: user.id,
        name: full_name,
        first_name: first_name,
        last_name: last_name,
        avatar_url: user.try(:avatar_url),
        closed_count: closed_count,
        closed_value: closed_value,
        formatted_closed_value: format_currency(closed_value),
        pipeline_count: pipeline_count,
        pipeline_value: pipeline_value,
        formatted_pipeline_value: format_currency(pipeline_value),
        activities: activities,
        activity_count: activities,
        conversion_rate: conversion_rate
      }
    end

    {
      reps: rep_rows.sort_by { |r| -r[:closed_value] },
      drill_down_url: '/deals'
    }
  end

  # ==================== PIPELINE COVERAGE ====================
  def pipeline_coverage
    pipeline_scope = @company.deals.where(deleted_at: nil).where.not(stage: closed_stages)
    pipeline_scope = pipeline_scope.where(location_id: Current.location_id) if location_filtered?

    pipeline_value = pipeline_scope.sum(:value).to_f
    deals_count    = pipeline_scope.count

    target = if @company.respond_to?(:revenue_target) && @company.revenue_target.to_f.positive?
               @company.revenue_target.to_f
             else
               last_month_start = Date.today.last_month.beginning_of_month
               last_month_end   = Date.today.last_month.end_of_month
               (calculate_revenue(last_month_start, last_month_end).to_f * 1.1)
             end

    coverage_ratio = target.positive? ? (pipeline_value / target).round(2) : 0.0

    {
      pipeline_value: pipeline_value,
      formatted_pipeline_value: format_currency(pipeline_value),
      target: target,
      formatted_target: format_currency(target),
      coverage_ratio: coverage_ratio,
      deals_count: deals_count,
      drill_down_url: '/deals'
    }
  end

  # ==================== STALE DEALS ALERT ====================
  def stale_deals_alert
    cutoff = 14.days.ago
    owner_field = find_dashboard_owner_field

    stale = @company.deals.where(deleted_at: nil)
                          .where.not(stage: closed_stages)
                          .where('(deals.last_activity_at IS NULL AND deals.created_at < :c) OR deals.last_activity_at < :c', c: cutoff)
    stale = stale.where(location_id: Current.location_id) if location_filtered?

    total_stale = stale.count

    by_owner = []
    if owner_field
      grouped = stale.where.not(owner_field => nil).group(owner_field).count
      user_lookup = User.where(id: grouped.keys, company_id: @company.id).index_by(&:id)
      by_owner = grouped.map do |uid, count|
        u = user_lookup[uid]
        oldest = stale.where(owner_field => uid).minimum(Arel.sql('COALESCE(deals.last_activity_at, deals.created_at)'))
        days = oldest ? ((Time.current - oldest) / 1.day).to_i : 0
        {
          user_id: uid,
          user_name: u ? ([u.first_name, u.last_name].compact.join(' ').presence || u.name.presence || u.email) : "User ##{uid}",
          count: count,
          oldest_days: days
        }
      end.sort_by { |row| -row[:count] }
    end

    deals_payload = stale.includes(:account, :contact)
                         .order(Arel.sql('COALESCE(deals.last_activity_at, deals.created_at) ASC'))
                         .limit(20).map do |d|
      anchor = d.last_activity_at || d.created_at
      days = anchor ? ((Time.current - anchor) / 1.day).to_i : 0
      owner_id = owner_field ? d.public_send(owner_field) : nil
      owner = owner_id ? User.where(id: owner_id, company_id: @company.id).pick(:first_name, :last_name, :email) : nil
      owner_name = owner ? ([owner[0], owner[1]].compact.join(' ').presence || owner[2]) : nil
      # Customer identity: prefer the denormalized column, then account/contact.
      customer_name = d.try(:customer_name).presence ||
                      d.account&.name.presence ||
                      [d.contact&.first_name, d.contact&.last_name].compact.join(' ').presence
      title = d.try(:name).presence || customer_name || "Deal ##{d.id}"
      {
        id: d.id,
        name: title,
        title: title,
        customer_name: customer_name,
        owner: owner_name,
        owner_name: owner_name || 'Unassigned',
        days_stale: days,
        value: d.value.to_f,
        formatted_value: format_currency(d.value),
        stage: d.stage
      }
    end

    {
      total_stale: total_stale,
      total_count: total_stale,
      by_owner: by_owner,
      deals: deals_payload,
      drill_down_url: '/deals?stale=true'
    }
  end

  # ==================== ENGAGEMENT HEATMAP ====================
  def engagement_heatmap
    cutoff = 7.days.ago.beginning_of_day

    daily_opens = CampaignSend.where(company_id: @company.id)
                              .where('opened_at >= ?', cutoff)
                              .group(Arel.sql("DATE(opened_at AT TIME ZONE 'UTC')"))
                              .sum(:open_count)

    daily_clicks = CampaignSend.where(company_id: @company.id)
                               .where('clicked_at >= ?', cutoff)
                               .group(Arel.sql("DATE(clicked_at AT TIME ZONE 'UTC')"))
                               .sum(:click_count)

    daily = (0..6).map do |i|
      d = (Date.today - (6 - i).days)
      key = d.to_s
      {
        date: key,
        opens: daily_opens[d].to_i || daily_opens[key].to_i,
        clicks: daily_clicks[d].to_i || daily_clicks[key].to_i
      }
    end

    total_opens  = daily.sum { |r| r[:opens] }
    total_clicks = daily.sum { |r| r[:clicks] }
    most_active  = daily.max_by { |r| r[:opens] + r[:clicks] }

    {
      daily: daily,
      total_opens: total_opens,
      total_clicks: total_clicks,
      most_active_day: most_active && (most_active[:opens] + most_active[:clicks]).positive? ? most_active[:date] : nil,
      drill_down_url: '/marketing/campaigns'
    }
  end

  # ============================================================
  # MARKETING CARDS
  # ============================================================

  # ==================== CAMPAIGN PERFORMANCE ====================
  def campaign_performance
    range = @date_range[:start_date].to_time..@date_range[:end_date].to_time.end_of_day

    campaigns = @company.campaigns.where(is_deleted: false)
                                  .where(status: %w[active running scheduled completed])

    sends_scope = CampaignSend.where(company_id: @company.id, sent_at: range)

    total_sends      = sends_scope.where.not(sent_at: nil).count
    total_delivered  = sends_scope.delivered.count
    total_opened     = sends_scope.where.not(opened_at: nil).count
    total_clicked    = sends_scope.where.not(clicked_at: nil).count
    total_bounced    = sends_scope.where.not(bounced_at: nil).count
    total_unsub      = sends_scope.where.not(unsubscribed_at: nil).count

    open_rate   = total_delivered.positive? ? (total_opened.to_f / total_delivered * 100).round(1) : 0.0
    click_rate  = total_delivered.positive? ? (total_clicked.to_f / total_delivered * 100).round(1) : 0.0
    bounce_rate = total_sends.positive?     ? (total_bounced.to_f / total_sends * 100).round(1)     : 0.0

    per_campaign = campaigns.map do |c|
      cs = sends_scope.where(campaign_id: c.id)
      sent = cs.where.not(sent_at: nil).count
      delivered = cs.delivered.count
      opened = cs.where.not(opened_at: nil).count
      clicked = cs.where.not(clicked_at: nil).count
      next nil if sent.zero?
      {
        id: c.id,
        name: c.name,
        sends: sent,
        open_rate:  delivered.positive? ? (opened.to_f / delivered * 100).round(1) : 0.0,
        click_rate: delivered.positive? ? (clicked.to_f / delivered * 100).round(1) : 0.0
      }
    end.compact.sort_by { |r| -r[:sends] }

    {
      total_sends: total_sends,
      total_delivered: total_delivered,
      total_opened: total_opened,
      total_clicked: total_clicked,
      total_bounced: total_bounced,
      total_unsubscribed: total_unsub,
      open_rate: open_rate,
      click_rate: click_rate,
      bounce_rate: bounce_rate,
      summary: {
        total_sent: total_sends,
        avg_open_rate: open_rate,
        avg_click_rate: click_rate
      },
      campaigns: per_campaign,
      drill_down_url: '/marketing/campaigns'
    }
  end

  # ==================== LEAD SOURCE BREAKDOWN ====================
  def lead_source_breakdown
    range = @date_range[:start_date]..@date_range[:end_date]

    leads_scope = @company.leads.where(created_at: range)
    leads_scope = leads_scope.where(location_id: Current.location_id) if location_filtered?

    total_leads = leads_scope.count
    by_source   = leads_scope.left_joins(:source).group('sources.id, sources.name').count
    ad_costs    = ad_campaign_cost_per_source(range)

    sources = by_source.map do |(source_id, source_name), count|
      pct = total_leads.positive? ? (count.to_f / total_leads * 100).round(1) : 0.0
      cpl = ad_costs[source_id] && count.positive? ? (ad_costs[source_id] / count).round(2) : nil
      display_name = source_name.presence || 'Unknown'
      {
        source_id: source_id,
        source_key: source_id.to_s,
        source_name: display_name,
        name: display_name,
        count: count,
        percentage: pct,
        cost_per_lead: cpl
      }
    end.sort_by { |r| -r[:count] }

    {
      sources: sources,
      total_leads: total_leads,
      total: total_leads,
      drill_down_url: '/crm/leads'
    }
  end

  # ==================== COMMUNICATION STATS ====================
  def communication_stats
    range = @date_range[:start_date].to_time..@date_range[:end_date].to_time.end_of_day

    emails_sent = Communication.where(company_id: @company.id, channel: 'email', direction: 'outbound')
                               .where(sent_at: range).count

    emails_opened = CommunicationEvent.joins(:communication)
                                      .where(communications: { company_id: @company.id, channel: 'email' })
                                      .where(event_type: 'opened')
                                      .where('communication_events.occurred_at' => range).count

    emails_clicked = CommunicationEvent.joins(:communication)
                                       .where(communications: { company_id: @company.id, channel: 'email' })
                                       .where(event_type: 'clicked')
                                       .where('communication_events.occurred_at' => range).count

    sms_sent = Communication.where(company_id: @company.id, channel: 'sms', direction: 'outbound')
                            .where(sent_at: range).count

    inbound = Communication.where(company_id: @company.id, direction: 'inbound')
                           .where(received_at: range).count
    outbound_total = Communication.where(company_id: @company.id, direction: 'outbound')
                                  .where(sent_at: range).count

    open_rate     = emails_sent.positive? ? (emails_opened.to_f / emails_sent * 100).round(1) : 0.0
    response_rate = outbound_total.positive? ? (inbound.to_f / outbound_total * 100).round(1) : 0.0

    {
      emails_sent: emails_sent,
      emails_opened: emails_opened,
      emails_clicked: emails_clicked,
      email_open_rate: open_rate,
      open_rate: open_rate,
      sms_sent: sms_sent,
      response_rate: response_rate,
      drill_down_url: '/communications'
    }
  end

  private

  # Calculate total revenue from payments
  def calculate_revenue(start_date, end_date)
    @company.payments
      .where(status: 'completed')
      .where(payment_date: start_date..end_date)
      .sum(:amount)
  end

  # Range covering the period immediately preceding @date_range, same length.
  def previous_period_range
    days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    prev_start = @date_range[:start_date] - (days + 1).days
    prev_end   = @date_range[:start_date] - 1.day
    prev_start..prev_end
  end

  def location_filtered?
    defined?(Current) && Current.respond_to?(:location_filtered?) && Current.location_filtered?
  end

  # Determine which deal column holds the rep — mirrors top_performers logic.
  def find_dashboard_owner_field
    cols = @company.deals.column_names
    %w[owner_id user_id assigned_to_id primary_salesperson_id created_by_id].find { |f| cols.include?(f) }
  end

  # Returns { source_id => total ad spend in range } for sources matched by name to ad_campaigns.
  def ad_campaign_cost_per_source(range)
    return {} unless defined?(AdCampaign)

    ad_spend_by_name = AdCampaign.where(company_id: @company.id, is_deleted: [false, nil])
                                 .where(updated_at: range)
                                 .group(:name).sum(:spend)
    return {} if ad_spend_by_name.empty?

    sources = @company.sources.where(name: ad_spend_by_name.keys).pluck(:id, :name)
    sources.each_with_object({}) do |(id, name), acc|
      acc[id] = ad_spend_by_name[name].to_f
    end
  rescue StandardError
    {}
  end

  # Generate sparkline data for revenue (last 30 days)
  def generate_revenue_sparkline
    end_date = @date_range[:end_date]
    start_date = end_date - 29.days
    
    # Group by date and sum revenue
    daily_revenue = @company.payments
      .where(status: 'completed')
      .where(payment_date: start_date..end_date)
      .group("DATE(payment_date)")
      .sum(:amount)
    
    # Fill in missing dates with 0
    sparkline = []
    (start_date..end_date).each do |date|
      sparkline << {
        date: date.strftime('%Y-%m-%d'),
        value: daily_revenue[date] || 0
      }
    end
    
    sparkline
  end

  # Generate sparkline data for deals (last 30 days)
  def generate_deals_sparkline
    end_date = @date_range[:end_date]
    start_date = end_date - 29.days
    
    # Group by date and count deals
    daily_deals = @company.deals
      .where(created_at: start_date..end_date)
      .where.not(stage: closed_stages)
      .group("DATE(created_at)")
      .count
    
    # Fill in missing dates with 0
    sparkline = []
    (start_date..end_date).each do |date|
      sparkline << {
        date: date.strftime('%Y-%m-%d'),
        value: daily_deals[date] || 0
      }
    end
    
    sparkline
  end

  # Generate sparkline data for leads (last 30 days)
  def generate_leads_sparkline
    end_date = @date_range[:end_date]
    start_date = end_date - 29.days
    
    # Group by date and count leads
    daily_leads = @company.leads
      .where(created_at: start_date..end_date)
      .group("DATE(created_at)")
      .count
    
    # Fill in missing dates with 0
    sparkline = []
    (start_date..end_date).each do |date|
      sparkline << {
        date: date.strftime('%Y-%m-%d'),
        value: daily_leads[date] || 0
      }
    end
    
    sparkline
  end

  # Generate sparkline data for service tickets (last 30 days)
  def generate_service_tickets_sparkline
    end_date = @date_range[:end_date]
    start_date = end_date - 29.days
    
    # Group by date and count tickets
    daily_tickets = @company.service_tickets
      .where(created_at: start_date..end_date)
      .where.not(status: ['completed', 'cancelled'])
      .group("DATE(created_at)")
      .count
    
    # Fill in missing dates with 0
    sparkline = []
    (start_date..end_date).each do |date|
      sparkline << {
        date: date.strftime('%Y-%m-%d'),
        value: daily_tickets[date] || 0
      }
    end
    
    sparkline
  end

  # Generate sparkline data for A/R (last 30 days)
  def generate_ar_sparkline
    end_date = @date_range[:end_date]
    start_date = end_date - 29.days
    
    # Calculate A/R balance for each day
    sparkline = []
    (start_date..end_date).each do |date|
      # Get all unpaid invoices as of this date
      ar_balance = @company.invoices
        .where('invoice_date <= ?', date)
        .where.not(status: ['paid', 'cancelled'])
        .sum(:amount_due)
      
      sparkline << {
        date: date.strftime('%Y-%m-%d'),
        value: ar_balance
      }
    end
    
    sparkline
  end

  # Generate sparkline data for A/P (last 30 days)
  def generate_ap_sparkline
    end_date = @date_range[:end_date]
    start_date = end_date - 29.days
    
    # Calculate A/P balance for each day
    sparkline = []
    (start_date..end_date).each do |date|
      # Get all pending payments as of this date
      ap_balance = @company.payments
        .where('created_at <= ?', date)
        .where(status: ['pending', 'processing'])
        .sum(:amount)
      
      sparkline << {
        date: date.strftime('%Y-%m-%d'),
        value: ap_balance
      }
    end
    
    sparkline
  end

  # Generate sparkline data for payments count (last 30 days)
  def generate_payments_sparkline
    end_date = @date_range[:end_date]
    start_date = end_date - 29.days
    
    # Group by date and count payments
    daily_payments = @company.payments
      .where(status: 'completed')
      .where(payment_date: start_date..end_date)
      .group("DATE(payment_date)")
      .count
    
    # Fill in missing dates with 0
    sparkline = []
    (start_date..end_date).each do |date|
      sparkline << {
        date: date.strftime('%Y-%m-%d'),
        value: daily_payments[date] || 0
      }
    end
    
    sparkline
  end

  # Generate sparkline data for inventory count (last 30 days)
  def generate_inventory_sparkline
    end_date = @date_range[:end_date]
    start_date = end_date - 29.days
    
    # Calculate inventory count for each day
    sparkline = []
    (start_date..end_date).each do |date|
      # Count available vehicles as of this date
      count = @company.vehicles
        .where(is_deleted: [false, nil])
        .where('created_at <= ?', date)
        .where(status: 'available')
        .count
      
      sparkline << {
        date: date.strftime('%Y-%m-%d'),
        value: count
      }
    end
    
    sparkline
  end

  # Generate empty sparkline (for leads or when no data)
  def generate_empty_sparkline
    end_date = @date_range[:end_date]
    start_date = end_date - 29.days
    
    sparkline = []
    (start_date..end_date).each do |date|
      sparkline << {
        date: date.strftime('%Y-%m-%d'),
        value: 0
      }
    end
    
    sparkline
  end

  # Calculate trend percentage and direction
  def calculate_trend(current_value, previous_value)
    return { percentage: 0, direction: 'neutral' } if previous_value.zero?
    
    percentage = ((current_value - previous_value) / previous_value.to_f * 100).round(1)
    direction = if percentage > 0
                  'up'
                elsif percentage < 0
                  'down'
                else
                  'neutral'
                end
    
    {
      percentage: percentage.abs,
      direction: direction
    }
  end

  # Parse date range options
  def parse_date_range(range_params)
    option = range_params[:option] || 'this_month'
    
    case option
    when 'today'
      {
        start_date: Date.today,
        end_date: Date.today
      }
    when 'yesterday'
      {
        start_date: Date.yesterday,
        end_date: Date.yesterday
      }
    when 'this_week'
      {
        start_date: Date.today.beginning_of_week,
        end_date: Date.today.end_of_week
      }
    when 'last_week'
      {
        start_date: Date.today.last_week.beginning_of_week,
        end_date: Date.today.last_week.end_of_week
      }
    when 'this_month'
      {
        start_date: Date.today.beginning_of_month,
        end_date: Date.today.end_of_month
      }
    when 'last_month'
      {
        start_date: Date.today.last_month.beginning_of_month,
        end_date: Date.today.last_month.end_of_month
      }
    when 'this_quarter'
      {
        start_date: Date.today.beginning_of_quarter,
        end_date: Date.today.end_of_quarter
      }
    when 'last_quarter'
      {
        start_date: (Date.today - 3.months).beginning_of_quarter,
        end_date: (Date.today - 3.months).end_of_quarter
      }
    when 'this_year'
      {
        start_date: Date.today.beginning_of_year,
        end_date: Date.today.end_of_year
      }
    when 'last_year'
      {
        start_date: Date.today.last_year.beginning_of_year,
        end_date: Date.today.last_year.end_of_year
      }
    when 'custom'
      {
        start_date: Date.parse(range_params[:start_date]),
        end_date: Date.parse(range_params[:end_date])
      }
    else
      # Default to this month
      {
        start_date: Date.today.beginning_of_month,
        end_date: Date.today.end_of_month
      }
    end
  rescue ArgumentError => e
    # If date parsing fails, default to this month
    {
      start_date: Date.today.beginning_of_month,
      end_date: Date.today.end_of_month
    }
  end

  # Format currency
  def format_currency(amount)
    ActionController::Base.helpers.number_to_currency(amount)
  end
  
  # Time ago helper
  def time_ago_in_words(time)
    seconds = (Time.now - time).to_i
    
    case seconds
    when 0..59
      "#{seconds}s ago"
    when 60..3599
      "#{seconds / 60}m ago"
    when 3600..86399
      "#{seconds / 3600}h ago"
    when 86400..604799
      "#{seconds / 86400}d ago"
    else
      time.strftime('%b %d')
    end
  end

  # ==================== SERVICE FINANCIAL METRICS ====================
  # These metrics require service_tickets table to have financial columns:
  # - labor_cost (decimal)
  # - parts_cost (decimal)
  # - total_cost (decimal)  
  # - billed_amount (decimal)
  # TODO: Add these columns to service_tickets table

  # ==================== SERVICE REVENUE ====================
  def service_revenue
    # Get total billed amount from service tickets
    current_revenue = @company.service_tickets
      .where(status: 'completed')
      .where(completed_at: @date_range[:start_date]..@date_range[:end_date])
      .sum(:billed_amount) || 0
    
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    
    previous_revenue = @company.service_tickets
      .where(status: 'completed')
      .where(completed_at: previous_start..previous_end)
      .sum(:billed_amount) || 0
    
    trend = calculate_trend(current_revenue, previous_revenue)
    
    {
      value: current_revenue,
      formatted_value: format_currency(current_revenue),
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      drill_down_url: '/service?status=completed'
    }
  rescue StandardError => e
    Rails.logger.error "[Service Revenue] Error: #{e.message}"
    empty_metric_response
  end

  # ==================== SERVICE LABOR COST ====================
  def service_labor_cost
    # Get total labor cost from completed service tickets
    current_cost = @company.service_tickets
      .where(status: 'completed')
      .where(completed_at: @date_range[:start_date]..@date_range[:end_date])
      .sum(:labor_cost) || 0
    
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    
    previous_cost = @company.service_tickets
      .where(status: 'completed')
      .where(completed_at: previous_start..previous_end)
      .sum(:labor_cost) || 0
    
    trend = calculate_trend(current_cost, previous_cost)
    
    {
      value: current_cost,
      formatted_value: format_currency(current_cost),
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      drill_down_url: '/service?status=completed'
    }
  rescue StandardError => e
    Rails.logger.error "[Service Labor Cost] Error: #{e.message}"
    empty_metric_response
  end

  # ==================== SERVICE PARTS COST ====================
  def service_parts_cost
    # Get total parts cost from completed service tickets
    current_cost = @company.service_tickets
      .where(status: 'completed')
      .where(completed_at: @date_range[:start_date]..@date_range[:end_date])
      .sum(:parts_cost) || 0
    
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    
    previous_cost = @company.service_tickets
      .where(status: 'completed')
      .where(completed_at: previous_start..previous_end)
      .sum(:parts_cost) || 0
    
    trend = calculate_trend(current_cost, previous_cost)
    
    {
      value: current_cost,
      formatted_value: format_currency(current_cost),
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      drill_down_url: '/service?status=completed'
    }
  rescue StandardError => e
    Rails.logger.error "[Service Parts Cost] Error: #{e.message}"
    empty_metric_response
  end

  # ==================== SERVICE PROFIT MARGIN ====================
  def service_profit_margin
    # Calculate profit margin: (Revenue - Total Cost) / Revenue * 100
    tickets = @company.service_tickets
      .where(status: 'completed')
      .where(completed_at: @date_range[:start_date]..@date_range[:end_date])
    
    revenue = tickets.sum(:billed_amount) || 0
    labor_cost = tickets.sum(:labor_cost) || 0
    parts_cost = tickets.sum(:parts_cost) || 0
    total_cost = labor_cost + parts_cost
    
    # Calculate margin percentage
    margin_percentage = revenue > 0 ? ((revenue - total_cost) / revenue * 100).round(1) : 0
    
    # Get previous period for trend
    previous_period_days = (@date_range[:end_date] - @date_range[:start_date]).to_i
    previous_start = @date_range[:start_date] - previous_period_days.days
    previous_end = @date_range[:start_date] - 1.day
    
    previous_tickets = @company.service_tickets
      .where(status: 'completed')
      .where(completed_at: previous_start..previous_end)
    
    previous_revenue = previous_tickets.sum(:billed_amount) || 0
    previous_labor = previous_tickets.sum(:labor_cost) || 0
    previous_parts = previous_tickets.sum(:parts_cost) || 0
    previous_total_cost = previous_labor + previous_parts
    previous_margin = previous_revenue > 0 ? ((previous_revenue - previous_total_cost) / previous_revenue * 100).round(1) : 0
    
    trend = calculate_trend(margin_percentage, previous_margin)
    
    {
      value: margin_percentage,
      formatted_value: "#{margin_percentage}%",
      trend_percentage: trend[:percentage],
      trend_direction: trend[:direction],
      drill_down_url: '/service?status=completed',
      breakdown: {
        revenue: revenue,
        formatted_revenue: format_currency(revenue),
        total_cost: total_cost,
        formatted_total_cost: format_currency(total_cost),
        profit: revenue - total_cost,
        formatted_profit: format_currency(revenue - total_cost)
      }
    }
  rescue StandardError => e
    Rails.logger.error "[Service Profit Margin] Error: #{e.message}"
    {
      value: 0,
      formatted_value: "0%",
      trend_percentage: 0,
      trend_direction: 'neutral',
      drill_down_url: '/service?status=completed',
      breakdown: {
        revenue: 0,
        formatted_revenue: format_currency(0),
        total_cost: 0,
        formatted_total_cost: format_currency(0),
        profit: 0,
        formatted_profit: format_currency(0)
      }
    }
  end

end
