# frozen_string_literal: true

class Api::V1::DealApprovalsController < ApplicationController
  before_action :set_company_scope
  before_action :authorize_accounting_update!
  before_action :load_deal, only: [:show, :update, :approve, :approve_commission]

  CLOSED_STAGES = %w[closed_won won closed completed].freeze
  VALID_STATUSES = %w[pending commission_pending posted].freeze
  DEFAULT_PER_PAGE = 50
  MAX_PER_PAGE = 200

  # GET /api/v1/deal_approvals/pending
  # Params:
  #   status     — pending (default) | commission_pending | posted
  #   start_date — filters actual_close_date / won_at (inclusive)
  #   end_date   — filters actual_close_date / won_at (inclusive)
  #   page       — defaults to 1
  #   per_page   — defaults to 50, capped at 200
  def pending
    status = (params[:status].presence || 'pending').to_s
    unless VALID_STATUSES.include?(status)
      render json: { error: "Invalid status. Allowed: #{VALID_STATUSES.join(', ')}" }, status: :bad_request
      return
    end

    page = [params[:page].to_i, 1].max
    per_page = [[params[:per_page].to_i, DEFAULT_PER_PAGE].max, MAX_PER_PAGE].min

    relation = deals_for_status(status)
    relation = apply_date_range(relation, params[:start_date], params[:end_date])

    total_count = relation.count
    deals = relation.limit(per_page).offset((page - 1) * per_page).to_a

    render json: {
      deals: deals.map { |d| pending_row(d) },
      total_count: total_count,
      page: page,
      per_page: per_page,
      status: status
    }
  end

  # GET /api/v1/deal_approvals/:id
  def show
    summary = Accounting::DealAccountingService.new(@deal).profitability_summary

    # Resolve vehicle display
    vehicle = @deal.try(:vehicle)
    vehicle_display = if vehicle
      [vehicle.try(:year), vehicle.try(:make), vehicle.try(:model)].compact.join(' ').presence
    else
      deal_name = @deal.try(:name).to_s
      deal_name.split(' \u2014 ').first.presence if deal_name.include?(' \u2014 ')
    end

    # Resolve customer name
    contact = @deal.try(:contact)
    customer_name = @deal.try(:customer_name).presence ||
      (contact && [contact.try(:first_name), contact.try(:last_name)].compact.join(' ').presence) ||
      contact&.try(:name) ||
      contact&.try(:email)

    render json: summary.merge(
      id: @deal.id,
      name: @deal.try(:name),
      deal_number: @deal.try(:deal_number),
      customer_name: customer_name,
      vehicle_display: vehicle_display,
      editable: editable_fields(@deal),
      vehicle: (vehicle_payload(vehicle) || {}).merge(display_name: vehicle_display),
      contact: contact_payload(contact),
      owner: owner_payload(@deal.try(:owner) || @deal.try(:user)),
      location: location_payload(@deal.try(:location)),
      deal_products: (@deal.try(:deal_products) || []).map { |p| product_payload(p) },
      commission_posted: @deal.try(:commission_posted) || false,
      gl_posted: @deal.try(:gl_posted) || false,
      delivery_state: @deal.try(:delivery_state),
      total_tax_amount: @deal.try(:total_tax_amount)
    )
  end

  # PATCH /api/v1/deal_approvals/:id
  def update
    if @deal.update(deal_update_params)
      service = Accounting::DealAccountingService.new(@deal)
      summary = service.profitability_summary

      # Return full deal data so the modal can re-hydrate all fields
      contact = @deal.try(:contact)
      customer_name = @deal.try(:customer_name).presence ||
        (contact && [contact.try(:first_name), contact.try(:last_name)].compact.join(' ').presence) ||
        contact&.try(:name)

      vehicle = @deal.try(:vehicle)
      vehicle_display = if vehicle
        [vehicle.try(:year), vehicle.try(:make), vehicle.try(:model)].compact.join(' ').presence
      else
        deal_name = @deal.try(:name).to_s
        deal_name.split(' \u2014 ').first.presence if deal_name.include?(' \u2014 ')
      end

      render json: summary.merge(
        id: @deal.id,
        name: @deal.try(:name),
        deal_number: @deal.try(:deal_number),
        customer_name: customer_name,
        vehicle_display: vehicle_display,
        vehicle: (vehicle_payload(vehicle) || {}).merge(display_name: vehicle_display),
        delivery_state: @deal.try(:delivery_state),
        state_tax_rate: @deal.try(:state_tax_rate),
        county_tax_rate: @deal.try(:county_tax_rate),
        city_tax_rate: @deal.try(:city_tax_rate),
        total_tax_amount: @deal.try(:total_tax_amount),
        commission_amount: @deal.try(:commission_amount),
        unit_cost: @deal.try(:home_cost) || @deal.try(:unit_cost),
        reconditioning_cost: @deal.try(:reconditioning_cost),
        floor_plan_interest: @deal.try(:floor_plan_interest),
        delivery_setup_cost: @deal.try(:delivery_setup_cost),
        pack_amount: @deal.try(:pack_amount),
        selling_price: @deal.try(:selling_price),
        gl_posted: @deal.try(:gl_posted) || false,
        commission_posted: @deal.try(:commission_posted) || false
      )
    else
      render json: { errors: @deal.errors }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/deal_approvals/:id/approve
  def approve
    if @deal.gl_posted?
      render json: { error: 'Deal already posted to GL' }, status: :unprocessable_entity
      return
    end

    service = Accounting::DealAccountingService.new(@deal)
    result = service.post_closing_entries!(user: current_user)

    if result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      @deal.reload

      # Auto-create invoice with draw schedule. GL posting succeeded; treat invoice
      # creation as best-effort so a failure here never reverts the approval.
      invoice_id = nil
      begin
        invoice = DealInvoiceService.new(@deal, user: current_user).create_invoice!
        invoice_id = invoice&.id
        Rails.logger.info("[DealApprovals] Auto-created invoice #{invoice_id} for deal #{@deal.id}") if invoice_id
      rescue => e
        Rails.logger.error("[DealApprovals] Invoice creation failed for deal #{@deal.id}: #{e.message}")
      end

      render json: {
        success: true,
        gl_posted: @deal.gl_posted?,
        gl_journal_entry_id: @deal.gl_journal_entry_id,
        deal_invoice_id: invoice_id || @deal.deal_invoice_id,
        tax: result[:tax],
        lines_count: result[:lines_count],
        message: result[:message]
      }
    end
  end

  # POST /api/v1/deal_approvals/:id/approve_commission
  def approve_commission
    # CRITICAL: Deal must be GL-posted before commission can be approved
    unless @deal.gl_posted?
      render json: { error: 'Cannot approve commission: deal must be GL-approved first' }, status: :unprocessable_entity
      return
    end

    result = post_commission_for_deal(@deal)

    if result[:error]
      render json: { error: result[:error] }, status: :unprocessable_entity
    else
      render json: { success: true, journal_entry: result[:journal_entry] }
    end
  end

  # POST /api/v1/deal_approvals/bulk_approve_commissions
  # Body: { deal_ids: [1, 2, 3] }
  def bulk_approve_commissions
    deal_ids = Array(params[:deal_ids]).map { |id| id.to_s.to_i }.reject(&:zero?).uniq

    if deal_ids.empty?
      render json: { error: 'deal_ids is required' }, status: :bad_request
      return
    end

    deals = @company.deals.where(id: deal_ids)
    found_ids = deals.pluck(:id)
    missing_ids = deal_ids - found_ids

    approved = 0
    failed = 0
    errors = missing_ids.map { |mid| { deal_id: mid, error: 'Deal not found' } }

    deals.find_each do |deal|
      result = post_commission_for_deal(deal)
      if result[:error]
        failed += 1
        errors << { deal_id: deal.id, error: result[:error] }
      else
        approved += 1
      end
    end

    failed += missing_ids.size

    render json: {
      approved: approved,
      failed: failed,
      errors: errors
    }
  end

  # GET /api/v1/deal_approvals/stats
  def stats
    closed = @company.deals.where(stage: CLOSED_STAGES)
    pending_scope = closed.where(gl_posted: [false, nil])
    commission_pending_scope = closed
                                 .where(gl_posted: true)
                                 .where(commission_posted: [false, nil])
                                 .where('commission_amount > 0')

    posted_today = @company.deals.where(gl_posted: true).where(gl_posted_at: Date.current.all_day).count
    total_posted_this_month = @company.deals.where(gl_posted: true)
                                       .where(gl_posted_at: Date.current.all_month).count

    render json: {
      pending_deals: pending_scope.count,
      pending_commissions: commission_pending_scope.count,
      posted_today: posted_today,
      total_posted_this_month: total_posted_this_month,
      total_revenue_pending: pending_scope.sum(:selling_price).to_f,
      total_commission_pending: commission_pending_scope.sum(:commission_amount).to_f,
      # Retained for backwards compatibility
      total_posted: @company.deals.where(gl_posted: true).count
    }
  end

  private

  def authorize_accounting_update!
    authorize_action!('accounting', 'update') || throw(:abort)
  end

  def load_deal
    @deal = @company.deals.find_by(id: params[:id])
    render json: { error: 'Deal not found' }, status: :not_found unless @deal
  end

  def pending_deals_scope
    @company.deals
            .includes(:vehicle, :contact, :owner, :user)
            .where(stage: CLOSED_STAGES)
            .where(gl_posted: [false, nil])
            .order(Arel.sql('COALESCE(actual_close_date, won_at::date, updated_at::date) DESC'))
  end

  def deals_for_status(status)
    case status
    when 'commission_pending'
      @company.deals
              .includes(:vehicle, :contact, :owner, :user)
              .where(stage: CLOSED_STAGES)
              .where(gl_posted: true)
              .where(commission_posted: [false, nil])
              .where('commission_amount > 0')
              .order(Arel.sql('COALESCE(actual_close_date, won_at::date, updated_at::date) DESC'))
    when 'posted'
      @company.deals
              .includes(:vehicle, :contact, :owner, :user)
              .where(gl_posted: true)
              .order(gl_posted_at: :desc)
    else
      pending_deals_scope
    end
  end

  def apply_date_range(relation, start_date, end_date)
    return relation if start_date.blank? && end_date.blank?

    start_d = parse_date(start_date)
    end_d   = parse_date(end_date)
    return relation if start_d.nil? && end_d.nil?

    if start_d && end_d
      relation.where(
        '(actual_close_date BETWEEN :s AND :e) OR (won_at::date BETWEEN :s AND :e)',
        s: start_d, e: end_d
      )
    elsif start_d
      relation.where('actual_close_date >= :s OR won_at::date >= :s', s: start_d)
    else
      relation.where('actual_close_date <= :e OR won_at::date <= :e', e: end_d)
    end
  end

  def parse_date(value)
    return nil if value.blank?
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def pending_row(deal)
    gl_je_id = deal.try(:gl_journal_entry_id)
    commission_je_id = deal.try(:commission_journal_entry_id)
    tax_je_ids = Array(deal.try(:tax_journal_entry_ids)).map(&:to_i).reject(&:zero?)
    related_je_ids = ([gl_je_id, commission_je_id] + tax_je_ids).compact.uniq
    je_numbers = je_numbers_by_id(related_je_ids)

    # Build profitability once and flatten key fields to top level
    prof = begin
      Accounting::DealAccountingService.new(deal).profitability_summary
    rescue => e
      Rails.logger.warn("[DealApprovals] profitability_summary failed for deal #{deal.id}: #{e.message}")
      {}
    end

    # Resolve customer name — prefer deal's own column, then contact
    contact = deal.try(:contact)
    customer_name = deal.try(:customer_name).presence ||
      (contact && [contact.try(:first_name), contact.try(:last_name)].compact.join(' ').presence) ||
      contact&.try(:name) ||
      contact&.try(:email) ||
      deal.try(:buyer_name)

    # Resolve vehicle — prefer association, fall back to deal name parsing
    vehicle = deal.try(:vehicle)
    vehicle_display = if vehicle
      [vehicle.try(:year), vehicle.try(:make), vehicle.try(:model)].compact.join(' ').presence
    else
      # Many deals store vehicle info in the deal name: "2024 Clayton Pulse — Williams..."
      deal_name = deal.try(:name).to_s
      deal_name.split(' — ').first.presence if deal_name.include?(' — ')
    end

    {
      id: deal.id,
      name: deal.try(:name),
      deal_number: deal.try(:deal_number),
      stage: deal.stage,
      actual_close_date: deal.try(:actual_close_date),
      closed_at: deal.try(:won_at),
      won_at: deal.try(:won_at),
      gl_posted_at: deal.try(:gl_posted_at)&.iso8601,
      # Financials — flat at top level for the FE table
      selling_price: deal.try(:selling_price),
      unit_cost: deal.try(:unit_cost) || deal.try(:home_cost),
      front_gross: prof[:front_gross],
      back_gross: prof[:back_gross],
      total_gross: prof[:total_gross],
      commission_amount: deal.try(:commission_amount),
      commission: deal.try(:commission_amount),
      net_profit: prof[:net_profit],
      total_tax_amount: deal.try(:total_tax_amount),
      delivery_state: deal.try(:delivery_state),
      state_tax_rate: deal.try(:state_tax_rate),
      county_tax_rate: deal.try(:county_tax_rate),
      city_tax_rate: deal.try(:city_tax_rate),
      # Status flags
      gl_posted: deal.try(:gl_posted) || false,
      commission_posted: deal.try(:commission_posted) || false,
      # Journal entry references
      gl_journal_entry_id: gl_je_id,
      gl_journal_entry_number: je_numbers[gl_je_id],
      commission_journal_entry_id: commission_je_id,
      commission_journal_entry_number: je_numbers[commission_je_id],
      tax_journal_entry_ids: tax_je_ids,
      tax_journal_entry_numbers: tax_je_ids.map { |id| je_numbers[id] }.compact,
      journal_entry_id: gl_je_id,
      journal_entry_number: je_numbers[gl_je_id],
      journal_entry_ids: related_je_ids,
      # Related entities
      customer_name: customer_name,
      vehicle_display: vehicle_display,
      salesperson_name: (deal.try(:owner) || deal.try(:user))&.then { |u| [u.try(:first_name), u.try(:last_name)].compact.join(' ').presence || u.try(:email) },
      vehicle: (vehicle_payload(vehicle) || {}).merge(display_name: vehicle_display),
      owner: owner_payload(deal.try(:owner) || deal.try(:user)),
      contact: contact_payload(contact),
      profitability: prof
    }
  end

  def je_numbers_by_id(ids)
    return {} if ids.empty?
    @company.journal_entries.where(id: ids).pluck(:id, :entry_number).to_h
  end

  def editable_fields(deal)
    {
      selling_price: deal.try(:selling_price),
      home_cost: deal.try(:home_cost),
      reconditioning_cost: deal.try(:reconditioning_cost),
      floor_plan_interest: deal.try(:floor_plan_interest),
      delivery_setup_cost: deal.try(:delivery_setup_cost),
      pack_amount: deal.try(:pack_amount),
      commission_amount: deal.try(:commission_amount),
      delivery_state: deal.try(:delivery_state),
      state_tax_rate: deal.try(:state_tax_rate),
      county_tax_rate: deal.try(:county_tax_rate),
      city_tax_rate: deal.try(:city_tax_rate)
    }
  end

  def vehicle_payload(vehicle)
    return nil unless vehicle
    {
      id: vehicle.id,
      year: vehicle.try(:year),
      make: vehicle.try(:make),
      model: vehicle.try(:model),
      stock_number: vehicle.try(:stock_number),
      vin: vehicle.try(:vin)
    }
  end

  def contact_payload(contact)
    return nil unless contact
    name = [contact.try(:first_name), contact.try(:last_name)].compact.join(' ').presence ||
           contact.try(:name) ||
           contact.try(:email)
    { id: contact.id, name: name, email: contact.try(:email) }
  end

  def owner_payload(user)
    return nil unless user
    name = [user.try(:first_name), user.try(:last_name)].compact.join(' ').presence || user.try(:email)
    { id: user.id, name: name, email: user.try(:email) }
  end

  def location_payload(location)
    return nil unless location
    { id: location.id, name: location.try(:name), state: location.try(:state) }
  end

  def product_payload(p)
    {
      id: p.id,
      name: p.try(:name) || p.try(:product_name) || p.try(:product_type),
      product_type: p.try(:product_type),
      amount: p.try(:price) || p.try(:amount) || p.try(:total)
    }
  end

  def deal_update_params
    permitted = params.require(:deal).permit(
      :selling_price, :home_cost, :unit_cost, :reconditioning_cost, :floor_plan_interest,
      :delivery_setup_cost, :pack_amount, :commission_amount, :commission, :delivery_state,
      :state_tax_rate, :county_tax_rate, :city_tax_rate, :total_tax_amount,
      :front_gross, :total_gross, :net_deal_profit, :net_profit,
      :payment_type, :lender_name, :financed_amount, :delivery_date, :down_payment_due_date
    )
    # Map aliases: unit_cost → home_cost, commission → commission_amount, net_profit → net_deal_profit
    permitted[:home_cost] = permitted.delete(:unit_cost) if permitted.key?(:unit_cost) && !permitted.key?(:home_cost)
    permitted[:commission_amount] = permitted.delete(:commission) if permitted.key?(:commission) && !permitted.key?(:commission_amount)
    permitted[:net_deal_profit] = permitted.delete(:net_profit) if permitted.key?(:net_profit)
    permitted
  end

  # Resolves the GL account to use for a commission posting.
  # Strategy: prefer an account whose name matches "<preferred_name>" (case-insensitive
  # exact), else any account whose name contains "commission" with the matching type,
  # else create at the preferred number if free, else create at the next available number.
  def ensure_commission_account!(preferred_number:, preferred_name:, account_type:, sub_type:)
    by_name = @company.chart_of_accounts.where('LOWER(name) = ?', preferred_name.downcase).first
    return by_name if by_name

    by_keyword = @company.chart_of_accounts
                          .where(account_type: account_type)
                          .where('LOWER(name) LIKE ?', '%commission%')
                          .order(:account_number)
                          .first
    return by_keyword if by_keyword

    if @company.chart_of_accounts.find_by(account_number: preferred_number).nil?
      return @company.chart_of_accounts.create!(
        account_number: preferred_number,
        name: preferred_name,
        account_type: account_type,
        sub_type: sub_type,
        normal_balance: account_type == 'expense' ? 'debit' : 'credit',
        is_active: true,
        is_header: false,
        is_system: true
      )
    end

    next_number = next_available_number(preferred_number)
    return nil if next_number.nil?

    @company.chart_of_accounts.create!(
      account_number: next_number,
      name: preferred_name,
      account_type: account_type,
      sub_type: sub_type,
      normal_balance: account_type == 'expense' ? 'debit' : 'credit',
      is_active: true,
      is_header: false,
      is_system: true
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("[DealApprovals] commission account creation failed: #{e.message}")
    nil
  end

  def next_available_number(start_number)
    base = start_number.to_i
    (base + 1..base + 50).each do |candidate|
      return candidate.to_s unless @company.chart_of_accounts.exists?(account_number: candidate.to_s)
    end
    nil
  end

  def deal_label(deal)
    vehicle = deal.try(:vehicle)
    title = deal.try(:title) || deal.try(:name)
    vehicle ? "#{vehicle.try(:year)} #{vehicle.try(:make)} #{vehicle.try(:model)} — #{title}" : (title || "Deal ##{deal.id}")
  end

  def deal_close_date(deal)
    (deal.try(:closed_at) || deal.try(:won_at) || deal.try(:actual_close_date))&.to_date || Date.current
  end

  # Posts the commission accrual JE for a single deal. Returns either
  # { journal_entry: {...} } on success or { error: '...' } on failure.
  def post_commission_for_deal(deal)
    commission = (deal.try(:commission_amount) || 0).to_d
    return { error: 'Deal has no commission to post' } if commission <= 0
    return { error: 'Commission already posted' } if deal.try(:commission_posted)

    expense_account = ensure_commission_account!(
      preferred_number: '5200',
      preferred_name: 'Commission Expense',
      account_type: 'expense',
      sub_type: 'operating_expense'
    )
    payable_account = ensure_commission_account!(
      preferred_number: '2120',
      preferred_name: 'Commission Payable',
      account_type: 'liability',
      sub_type: 'current_liability'
    )

    return { error: 'Could not resolve commission GL accounts' } if expense_account.nil? || payable_account.nil?

    service = Accounting::ManualPostingService.new(@company)
    je = service.post_simple!(
      debit_account: expense_account,
      credit_account: payable_account,
      amount: commission,
      memo: "Commission accrual — #{deal_label(deal)}",
      entry_date: deal_close_date(deal),
      source_entity: deal,
      location_id: deal.try(:location_id),
      department: 'sales',
      contact_id: deal.try(:contact_id),
      deal_id: deal.id,
      vehicle_id: deal.try(:vehicle_id),
      posted_by: current_user
    )

    return { error: 'Failed to post commission journal entry' } if je.nil?

    deal.update!(
      commission_posted: true,
      commission_posted_at: Time.current,
      commission_journal_entry_id: je.id
    )

    {
      journal_entry: {
        id: je.id,
        entry_date: je.entry_date,
        memo: je.memo,
        amount: commission,
        debit_account: { id: expense_account.id, account_number: expense_account.account_number, name: expense_account.name },
        credit_account: { id: payable_account.id, account_number: payable_account.account_number, name: payable_account.name }
      }
    }
  rescue ActiveRecord::RecordInvalid => e
    { error: e.message }
  end
end
