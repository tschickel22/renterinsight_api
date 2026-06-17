# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# BudgetService
#
# Centralizes budgeting logic: data analysis, budget creation
# (prior-year copy / wizard / AI), consolidation roll-up, and
# variance reporting.
class BudgetService
  ANTHROPIC_API_URL = 'https://api.anthropic.com/v1/messages'
  ANTHROPIC_MODEL   = 'claude-sonnet-4-6'

  # =========================================================================
  # FISCAL YEAR HELPERS
  # =========================================================================

  # Returns the [start_date, end_date] of the company's fiscal year.
  def self.fiscal_year_range(company, fiscal_year)
    start_month = fiscal_year_start_month(company)
    start_date  = Date.new(fiscal_year, start_month, 1)
    end_date    = (start_date >> 12) - 1
    [start_date, end_date]
  end

  def self.fiscal_year_start_month(company)
    company.accounting_settings&.fiscal_year_start_month || 1
  end

  # Convert a calendar month (1-12) to the fiscal-month index (1-12)
  # given the company's fiscal_year_start_month.
  def self.calendar_to_fiscal_month(calendar_month, start_month)
    ((calendar_month - start_month) % 12) + 1
  end

  # =========================================================================
  # DATA ANALYSIS
  # =========================================================================

  # Returns coverage information about historical journal-entry data for
  # a given fiscal year, which helps the UI decide which budget-creation
  # workflow to offer (prior-year copy, partial annualization, or wizard).
  def self.data_coverage(company, fiscal_year, location_id: nil)
    start_date, end_date = fiscal_year_range(company, fiscal_year)
    start_month          = fiscal_year_start_month(company)

    scope = company.journal_entries
                   .posted
                   .where(entry_date: start_date..end_date)
    scope = scope.where(location_id: location_id) if location_id.present?

    calendar_months_present = scope.distinct.pluck(
      Arel.sql('EXTRACT(YEAR FROM entry_date)::int'),
      Arel.sql('EXTRACT(MONTH FROM entry_date)::int')
    )

    fiscal_months_with_data = calendar_months_present.map do |year, month|
      calendar_to_fiscal_month(month, start_month)
    end.uniq.sort

    months_without_data = (1..12).to_a - fiscal_months_with_data
    coverage_count      = fiscal_months_with_data.size
    coverage_percent    = ((coverage_count / 12.0) * 100).round(1)

    first_month_label = nil
    last_month_label  = nil
    if calendar_months_present.any?
      sorted = calendar_months_present.sort
      first_month_label = Date.new(sorted.first[0],  sorted.first[1],  1).strftime('%B %Y')
      last_month_label  = Date.new(sorted.last[0],   sorted.last[1],   1).strftime('%B %Y')
    end

    {
      has_data:           coverage_count.positive?,
      months_with_data:   fiscal_months_with_data,
      months_without_data: months_without_data,
      coverage_count:     coverage_count,
      total_months:       12,
      coverage_percent:   coverage_percent,
      first_data_month:   first_month_label,
      last_data_month:    last_month_label,
      is_partial:         coverage_count.positive? && coverage_count < 12,
      is_empty:           coverage_count.zero?
    }
  end

  # Returns: { account_id => { 1 => amount, 2 => amount, ..., 12 => amount } }
  # Amounts are net (debit - credit for debit-normal accounts;
  # credit - debit for credit-normal accounts), expressed as positive numbers
  # in the account's natural direction.
  def self.actuals_by_month(company, fiscal_year, location_id: nil)
    start_date, end_date = fiscal_year_range(company, fiscal_year)
    start_month          = fiscal_year_start_month(company)

    scope = JournalEntryLine
              .joins(:journal_entry, :chart_of_account)
              .where(journal_entries: { company_id: company.id, is_void: false,
                                        entry_date: start_date..end_date })
    scope = scope.where(journal_entries: { location_id: location_id }) if location_id.present?

    rows = scope.group(
      'journal_entry_lines.chart_of_account_id',
      'chart_of_accounts.normal_balance',
      Arel.sql('EXTRACT(MONTH FROM journal_entries.entry_date)::int'),
      Arel.sql('EXTRACT(YEAR FROM journal_entries.entry_date)::int')
    ).pluck(
      'journal_entry_lines.chart_of_account_id',
      'chart_of_accounts.normal_balance',
      Arel.sql('EXTRACT(MONTH FROM journal_entries.entry_date)::int'),
      Arel.sql('EXTRACT(YEAR FROM journal_entries.entry_date)::int'),
      Arel.sql('COALESCE(SUM(journal_entry_lines.debit_amount), 0)'),
      Arel.sql('COALESCE(SUM(journal_entry_lines.credit_amount), 0)')
    )

    result = Hash.new { |h, k| h[k] = (1..12).each_with_object({}) { |m, hh| hh[m] = 0.to_d } }

    rows.each do |account_id, normal_balance, calendar_month, _year, sum_debit, sum_credit|
      fiscal_month = calendar_to_fiscal_month(calendar_month, start_month)
      net = if normal_balance == 'debit'
              sum_debit.to_d - sum_credit.to_d
            else
              sum_credit.to_d - sum_debit.to_d
            end
      result[account_id][fiscal_month] += net
    end

    result
  end

  # Project partial-year data to a full year.  Preserves seasonality
  # when 3+ months of data exist; otherwise distributes evenly.
  def self.annualize_partial_data(actuals_by_month, coverage)
    months_with_data = coverage[:months_with_data]
    coverage_count   = coverage[:coverage_count]
    return actuals_by_month if coverage_count.zero? || coverage_count == 12

    actuals_by_month.each_with_object({}) do |(account_id, monthly), result|
      total_actual    = months_with_data.sum { |m| monthly[m].to_d }
      annualized_total = coverage_count.zero? ? 0.to_d : (total_actual / coverage_count) * 12

      distributed = if coverage_count >= 3 && total_actual.nonzero?
                      pattern = months_with_data.map { |m| monthly[m].to_d }
                      pattern_sum = pattern.sum
                      ratios = pattern.map { |v| v / pattern_sum }
                      avg_ratio = ratios.sum / ratios.size
                      (1..12).map do |m|
                        idx = months_with_data.index(m)
                        ratio = idx ? ratios[idx] : avg_ratio
                        (annualized_total * ratio).round(2)
                      end
                    else
                      per_month = (annualized_total / 12).round(2)
                      Array.new(12, per_month)
                    end

      result[account_id] = (1..12).each_with_object({}) { |m, h| h[m] = distributed[m - 1] }
    end
  end

  # =========================================================================
  # BUDGET CREATION
  # =========================================================================

  def self.create_from_prior_year(company:, source_year:, target_year:, location_id: nil,
                                  growth_percent: 0, name: nil, created_by: nil)
    growth_factor = 1 + (growth_percent.to_f / 100.0)
    coverage      = data_coverage(company, source_year, location_id: location_id)

    source_budget_scope = company.budgets.standalone.by_fiscal_year(source_year)
    source_budget = location_id.present? ? source_budget_scope.where(location_id: location_id).first
                                          : source_budget_scope.where(location_id: nil).first

    monthly_by_account = nil
    source_label       = nil

    if source_budget
      monthly_by_account = source_budget.budget_lines.each_with_object({}) do |line, h|
        h[line.chart_of_account_id] = (1..12).each_with_object({}) { |m, hh| hh[m] = line.month_amount(m).to_d }
      end
      source_label = "budget:#{source_budget.id}"
    elsif coverage[:has_data]
      raw = actuals_by_month(company, source_year, location_id: location_id)
      monthly_by_account = coverage[:is_partial] ? annualize_partial_data(raw, coverage) : raw
      source_label = coverage[:is_partial] ? 'actuals_annualized' : 'actuals_full_year'
    else
      # No prior data at all — create budget with zero-amount lines for all active
      # non-header accounts so the user has a starting structure to fill in.
      accounts = company.chart_of_accounts.active.where(is_header: false)
      monthly_by_account = accounts.each_with_object({}) do |acct, h|
        h[acct.id] = (1..12).each_with_object({}) { |m, hh| hh[m] = 0.to_d }
      end
      source_label = 'blank_scaffold'
    end

    target_name = name.presence || "#{target_year} Budget"

    # Check for duplicate before attempting create
    existing = company.budgets.find_by(
      fiscal_year: target_year,
      location_id: location_id,
      name: target_name
    )
    if existing
      return ServiceResult.error(
        "A budget named '#{target_name}' already exists for FY #{target_year}. " \
        "Choose a different name or edit the existing budget."
      )
    end

    budget = nil
    Budget.transaction do
      budget = company.budgets.create!(
        name:               target_name,
        fiscal_year:        target_year,
        location_id:        location_id,
        budget_type:        'annual',
        status:             'draft',
        consolidation_type: 'standalone',
        created_by_id:      created_by&.id,
        metadata:           {
          'source'         => 'prior_year',
          'source_year'    => source_year,
          'source_label'   => source_label,
          'growth_percent' => growth_percent.to_f,
          'data_coverage'  => coverage.deep_stringify_keys,
          'annualized'     => coverage[:is_partial]
        }
      )

      monthly_by_account.each do |account_id, months|
        line = budget.budget_lines.build(chart_of_account_id: account_id)
        (1..12).each do |m|
          adjusted = (months[m].to_d * growth_factor.to_d).round(2)
          line.set_month_amount(m, adjusted)
        end
        line.save!
      end
    end

    ServiceResult.ok(budget)
  end

  def self.create_from_wizard(company:, fiscal_year:, location_id: nil,
                              wizard_inputs:, name: nil, created_by: nil)
    inputs = wizard_inputs.transform_keys(&:to_s)

    %w[planned_home_sales_per_month average_selling_price].each do |required|
      if inputs[required].blank?
        return ServiceResult.error("wizard_inputs.#{required} is required")
      end
    end

    accounts = company.chart_of_accounts.active.where(is_header: false).order(:account_number)
    if accounts.empty?
      return ServiceResult.error('Chart of accounts is empty — set up the COA before running the Budget Wizard.')
    end

    location_label = location_id.present? ? company.locations.find_by(id: location_id)&.name : 'Company-Wide'

    ai_response = call_anthropic_for_wizard(
      accounts:       accounts,
      fiscal_year:    fiscal_year,
      location_label: location_label || 'Company-Wide',
      inputs:         inputs
    )

    return ai_response if ai_response.error?

    suggestions    = ai_response.data[:suggestions] || []
    token_usage    = ai_response.data[:token_usage] || { input: 0, output: 0 }
    target_name    = name.presence || "#{fiscal_year} Budget (Wizard)"

    budget = nil
    Budget.transaction do
      budget = company.budgets.create!(
        name:               target_name,
        fiscal_year:        fiscal_year,
        location_id:        location_id,
        budget_type:        'annual',
        status:             'draft',
        consolidation_type: 'standalone',
        created_by_id:      created_by&.id,
        metadata:           {
          'source'        => 'wizard',
          'wizard_inputs' => inputs.deep_stringify_keys,
          'ai_model'      => ANTHROPIC_MODEL,
          'token_usage'   => token_usage.deep_stringify_keys
        }
      )

      suggestions.each do |sug|
        account_id = sug['account_id'] || sug[:account_id]
        months_arr = sug['months']     || sug[:months] || []
        next unless account_id && months_arr.is_a?(Array) && months_arr.size == 12
        next unless accounts.exists?(id: account_id)

        line = budget.budget_lines.build(chart_of_account_id: account_id,
                                         notes: sug['reasoning'] || sug[:reasoning])
        months_arr.each_with_index { |amt, idx| line.set_month_amount(idx + 1, amt.to_d.round(2)) }
        line.save!
      end
    end

    ServiceResult.ok(budget)
  end

  # =========================================================================
  # CONSOLIDATION
  # =========================================================================

  # Rebuild the read-only consolidated budget by summing all standalone
  # location-level budgets for the given fiscal year. Idempotent.
  def self.rebuild_consolidated(company, fiscal_year)
    location_budgets = company.budgets
                              .standalone
                              .by_fiscal_year(fiscal_year)
                              .where.not(location_id: nil)

    consolidated = company.budgets
                          .consolidated
                          .find_or_initialize_by(fiscal_year: fiscal_year, location_id: nil)
    consolidated.assign_attributes(
      name:         "#{fiscal_year} Consolidated Budget",
      budget_type:  'annual',
      status:       consolidated.persisted? ? consolidated.status : 'active',
      description:  "Auto-generated roll-up of all location-level budgets for FY#{fiscal_year}.",
      metadata:     consolidated.metadata.merge(
        'source'                  => 'consolidated_rollup',
        'last_rebuilt_at'         => Time.current.iso8601,
        'source_budget_ids'       => location_budgets.pluck(:id),
        'source_location_count'   => location_budgets.count
      ).deep_stringify_keys
    )

    Budget.transaction do
      consolidated.save!

      if location_budgets.empty?
        consolidated.budget_lines.destroy_all
        return consolidated
      end

      lines_by_account = Hash.new do |h, k|
        h[k] = (1..12).each_with_object({}) { |m, hh| hh[m] = 0.to_d }
      end

      BudgetLine.where(budget_id: location_budgets.select(:id)).find_each do |line|
        (1..12).each { |m| lines_by_account[line.chart_of_account_id][m] += line.month_amount(m).to_d }
      end

      account_ids = lines_by_account.keys
      consolidated.budget_lines.where.not(chart_of_account_id: account_ids).destroy_all if account_ids.any?
      consolidated.budget_lines.destroy_all if account_ids.empty?

      lines_by_account.each do |account_id, months|
        line = consolidated.budget_lines.find_or_initialize_by(chart_of_account_id: account_id)
        (1..12).each { |m| line.set_month_amount(m, months[m].round(2)) }
        line.save!
      end
    end

    consolidated.reload
  end

  # =========================================================================
  # AI SUGGESTIONS
  # =========================================================================

  def self.ai_suggest_amounts(company, budget, account_ids: [])
    target_lines = budget.budget_lines.includes(:chart_of_account)
    target_lines = target_lines.where(chart_of_account_id: account_ids) if account_ids.present?
    return ServiceResult.error('No matching budget lines') if target_lines.empty?

    # Gather up to 2 prior years of monthly actuals.
    prior_year      = budget.fiscal_year - 1
    two_years_ago   = budget.fiscal_year - 2
    prior_actuals   = actuals_by_month(company, prior_year,    location_id: budget.location_id)
    older_actuals   = actuals_by_month(company, two_years_ago, location_id: budget.location_id)
    prior_coverage  = data_coverage(company, prior_year,       location_id: budget.location_id)
    older_coverage  = data_coverage(company, two_years_ago,    location_id: budget.location_id)

    accounts_payload = target_lines.map do |line|
      acct = line.chart_of_account
      {
        account_id:           acct.id,
        account_number:       acct.account_number,
        account_name:         acct.name,
        account_type:         acct.account_type,
        prior_year_monthly:   format_monthly(prior_actuals[acct.id]),
        two_years_ago_monthly: format_monthly(older_actuals[acct.id]),
        data_note:            data_note_for(prior_coverage, older_coverage)
      }
    end

    location_label = budget.location&.name || 'Company-Wide'

    ai_response = call_anthropic_for_suggestions(
      accounts:       accounts_payload,
      fiscal_year:    budget.fiscal_year,
      location_label: location_label
    )
    return ai_response if ai_response.error?

    # Persist suggestion history (don't auto-apply amounts).
    history = (budget.metadata['ai_suggestion_history'] || []).dup
    history << {
      'requested_at' => Time.current.iso8601,
      'account_ids'  => target_lines.map(&:chart_of_account_id),
      'token_usage'  => (ai_response.data[:token_usage] || {}).deep_stringify_keys
    }
    budget.update_column(:metadata, budget.metadata.merge('ai_suggestion_history' => history).deep_stringify_keys)

    ServiceResult.ok(
      suggestions: ai_response.data[:suggestions],
      token_usage: ai_response.data[:token_usage]
    )
  end

  # =========================================================================
  # VARIANCE
  # =========================================================================

  # period: 'month' | 'quarter' | 'ytd' | 'annual'
  # month: 1..12 (fiscal month) — required when period = 'month'
  # quarter: 1..4 — required when period = 'quarter'
  def self.calculate_variance(budget, period:, month: nil, quarter: nil)
    company       = budget.company
    start_month   = fiscal_year_start_month(company)
    fy_start, fy_end = fiscal_year_range(company, budget.fiscal_year)

    fiscal_months_in_period =
      case period.to_s
      when 'month'
        raise ArgumentError, 'month required for period=month' unless month
        [month.to_i]
      when 'quarter'
        raise ArgumentError, 'quarter required for period=quarter' unless quarter
        q = quarter.to_i
        ((q - 1) * 3 + 1..q * 3).to_a
      when 'ytd'
        today = Date.current
        if today < fy_start
          []
        elsif today > fy_end
          (1..12).to_a
        else
          months_elapsed = ((today.year * 12 + today.month) - (fy_start.year * 12 + fy_start.month)) + 1
          (1..months_elapsed).to_a
        end
      when 'annual', 'full_year'
        (1..12).to_a
      else
        raise ArgumentError, "Unknown period: #{period}"
      end

    if fiscal_months_in_period.empty?
      return empty_variance_report(budget, period: period, month: month, quarter: quarter)
    end

    period_start_calendar = fiscal_to_date(budget.fiscal_year, fiscal_months_in_period.first, start_month)
    period_end_calendar   = (fiscal_to_date(budget.fiscal_year, fiscal_months_in_period.last,  start_month) >> 1) - 1

    location_filter =
      if budget.consolidated?
        nil
      else
        budget.location_id
      end

    actuals = actuals_by_month(company, budget.fiscal_year, location_id: location_filter)

    # Budget vs Actual only covers P&L accounts (Revenue + Expense).
    # Balance-sheet accounts (asset/liability/equity) are excluded.
    lines = budget.budget_lines.includes(:chart_of_account)
                 .joins(:chart_of_account)
                 .where(chart_of_accounts: { account_type: %w[revenue expense] })
                 .to_a

    rows = lines.map do |line|
      acct          = line.chart_of_account
      budget_amount = fiscal_months_in_period.sum { |m| line.month_amount(m).to_d }
      actual_amount = fiscal_months_in_period.sum { |m| actuals.dig(acct.id, m).to_d }
      variance_amt  = actual_amount - budget_amount
      variance_pct  = budget_amount.nonzero? ? ((variance_amt / budget_amount) * 100).round(2).to_f : nil
      status        = variance_status(account_type: acct.account_type,
                                      budget_amount: budget_amount,
                                      actual_amount: actual_amount)

      {
        account_id:       acct.id,
        account_number:   acct.account_number,
        account_name:     acct.name,
        account_type:     acct.account_type,
        budget_amount:    budget_amount.round(2),
        actual_amount:    actual_amount.round(2),
        variance_amount:  variance_amt.round(2),
        variance_percent: variance_pct,
        status:           status
      }
    end

    grouped  = rows.group_by { |r| r[:account_type] }
    subtotals = grouped.transform_values do |group|
      b = group.sum { |r| r[:budget_amount].to_d }
      a = group.sum { |r| r[:actual_amount].to_d }
      v = a - b
      {
        budget_amount:    b.round(2),
        actual_amount:    a.round(2),
        variance_amount:  v.round(2),
        variance_percent: b.nonzero? ? ((v / b) * 100).round(2).to_f : nil
      }
    end

    revenue_subtotal = subtotals['revenue'] || zero_subtotal
    expense_subtotal = subtotals['expense'] || zero_subtotal
    cogs_subtotal    = subtotals['cost_of_goods_sold'] || zero_subtotal

    net_income_budget = revenue_subtotal[:budget_amount] - expense_subtotal[:budget_amount] - cogs_subtotal[:budget_amount]
    net_income_actual = revenue_subtotal[:actual_amount] - expense_subtotal[:actual_amount] - cogs_subtotal[:actual_amount]
    net_income_var    = net_income_actual - net_income_budget

    {
      budget: {
        id:                 budget.id,
        name:               budget.name,
        fiscal_year:        budget.fiscal_year,
        location_id:        budget.location_id,
        location_name:      budget.location_name,
        consolidation_type: budget.consolidation_type
      },
      period: {
        kind:                  period,
        month:                 month,
        quarter:               quarter,
        fiscal_months:         fiscal_months_in_period,
        start_date:            period_start_calendar.iso8601,
        end_date:              period_end_calendar.iso8601,
        fiscal_year_start_month: start_month
      },
      groups: grouped.map do |account_type, group_rows|
        {
          account_type: account_type,
          rows:         group_rows,
          subtotal:     subtotals[account_type]
        }
      end,
      net_income: {
        budget_amount:    net_income_budget.round(2),
        actual_amount:    net_income_actual.round(2),
        variance_amount:  net_income_var.round(2),
        variance_percent: net_income_budget.nonzero? ? ((net_income_var / net_income_budget) * 100).round(2).to_f : nil
      }
    }
  end

  # =========================================================================
  # PRIVATE HELPERS (class)
  # =========================================================================

  def self.fiscal_to_date(fiscal_year, fiscal_month, start_month)
    months_offset    = fiscal_month - 1
    base_year        = fiscal_year
    calendar_month   = start_month + months_offset
    calendar_year    = base_year
    while calendar_month > 12
      calendar_month -= 12
      calendar_year  += 1
    end
    Date.new(calendar_year, calendar_month, 1)
  end

  def self.format_monthly(monthly)
    return nil if monthly.nil?
    return nil if monthly.values.all? { |v| v.to_d.zero? }
    monthly.transform_values { |v| v.to_d.round(2).to_f }
  end

  def self.data_note_for(prior_coverage, older_coverage)
    return 'No historical data' if prior_coverage[:is_empty] && older_coverage[:is_empty]
    parts = []
    if prior_coverage[:has_data]
      label = prior_coverage[:is_partial] ?
                "Partial: #{prior_coverage[:coverage_count]} months (#{prior_coverage[:first_data_month]} - #{prior_coverage[:last_data_month]})" :
                'Full year'
      parts << "Prior year: #{label}"
    end
    if older_coverage[:has_data]
      label = older_coverage[:is_partial] ?
                "Partial: #{older_coverage[:coverage_count]} months" :
                'Full year'
      parts << "Two years ago: #{label}"
    end
    parts.join(' | ')
  end

  def self.variance_status(account_type:, budget_amount:, actual_amount:)
    b = budget_amount.to_d
    a = actual_amount.to_d
    return 'no_budget' if b.zero?

    if account_type == 'revenue'
      return 'favorable'   if a >= b
      ratio = a / b
      return 'caution'     if ratio >= 0.9.to_d
      'unfavorable'
    else
      # expense, cogs, etc. — lower-is-better
      return 'favorable'   if a <= b
      ratio = a / b
      return 'caution'     if ratio <= 1.1.to_d
      'unfavorable'
    end
  end

  def self.zero_subtotal
    { budget_amount: 0.to_d, actual_amount: 0.to_d, variance_amount: 0.to_d, variance_percent: nil }
  end

  def self.empty_variance_report(budget, period:, month:, quarter:)
    {
      budget: {
        id:                 budget.id,
        name:               budget.name,
        fiscal_year:        budget.fiscal_year,
        location_id:        budget.location_id,
        location_name:      budget.location_name,
        consolidation_type: budget.consolidation_type
      },
      period: { kind: period, month: month, quarter: quarter, fiscal_months: [] },
      groups: [],
      net_income: zero_subtotal
    }
  end

  # =========================================================================
  # ANTHROPIC API CALLS
  # =========================================================================

  def self.call_anthropic_for_wizard(accounts:, fiscal_year:, location_label:, inputs:)
    system_prompt = <<~SYS
      You are a financial analyst specializing in manufactured home dealerships.
      You build full-year budgets from a small set of business inputs and the
      dealer's chart of accounts. Always respond with ONLY valid JSON — no
      markdown, no explanation outside the JSON structure. Use industry
      benchmarks when data is missing. Distribute revenue with realistic
      seasonality (peak in spring/summer for manufactured home sales). Match
      expenses to expected revenue: COGS scales with sales, fixed costs
      (rent, insurance, utilities) are stable, commissions scale with sales,
      payroll is generally steady.
    SYS

    user_payload = {
      task: 'generate_full_year_budget',
      context: {
        company_type:    'manufactured_home_dealer',
        fiscal_year:     fiscal_year,
        location:        location_label
      },
      inputs:   inputs,
      accounts: accounts.map { |a|
        { account_id: a.id, account_number: a.account_number, account_name: a.name,
          account_type: a.account_type, sub_type: a.sub_type }
      },
      response_schema: {
        suggestions: [
          { account_id: 'integer',
            months: 'array of 12 numbers',
            reasoning: 'short string explaining the rationale' }
        ]
      },
      instructions: 'Generate a `suggestions` array with one entry per account that should appear in the budget. Skip accounts that should be zero (e.g. inventory accounts not relevant). Use the inputs to drive revenue, COGS, commissions, and overhead. Months are calendar-month-ordered within the dealership fiscal year (index 0 = first fiscal month).'
    }

    invoke_anthropic(system_prompt: system_prompt, user_payload: user_payload)
  end

  def self.call_anthropic_for_suggestions(accounts:, fiscal_year:, location_label:)
    system_prompt = <<~SYS
      You are a financial analyst specializing in manufactured home dealerships.
      You analyze historical financial data and suggest budget amounts. Always
      respond with ONLY valid JSON — no markdown, no explanation outside the
      JSON structure. If no historical data is available, use manufactured
      housing industry benchmarks and the account type/name to make reasonable
      suggestions. Preserve seasonality when prior-year data shows a clear
      pattern.
    SYS

    user_payload = {
      task: 'suggest_account_budget_amounts',
      accounts: accounts,
      context: {
        company_type:  'manufactured_home_dealer',
        fiscal_year:   fiscal_year,
        location:      location_label
      },
      response_schema: {
        suggestions: [
          { account_id: 'integer',
            months: 'array of 12 numbers, fiscal months ordered',
            reasoning: 'short string' }
        ]
      },
      instructions: 'For every account in `accounts`, produce a 12-month suggestion. Months are fiscal-year ordered (index 0 = first fiscal month).'
    }

    invoke_anthropic(system_prompt: system_prompt, user_payload: user_payload)
  end

  def self.invoke_anthropic(system_prompt:, user_payload:)
    api_key = ENV['ANTHROPIC_API_KEY']
    return ServiceResult.error('ANTHROPIC_API_KEY is not configured') if api_key.blank?

    uri  = URI(ANTHROPIC_API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl     = true
    http.read_timeout = 120
    http.open_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Content-Type']      = 'application/json'
    request['x-api-key']         = api_key
    request['anthropic-version'] = '2023-06-01'
    request.body = {
      model:      ANTHROPIC_MODEL,
      max_tokens: 4000,
      system:     system_prompt,
      messages:   [{ role: 'user', content: user_payload.to_json }]
    }.to_json

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.error("[BudgetService] Anthropic API error #{response.code}: #{response.body}")
      return ServiceResult.error("Anthropic API error #{response.code}: #{response.body.to_s.first(200)}")
    end

    body  = JSON.parse(response.body)
    text  = extract_text_from_anthropic_response(body)
    json_text = strip_markdown_fence(text)
    parsed = JSON.parse(json_text)

    usage = body['usage'] || {}
    ServiceResult.ok(
      suggestions: parsed['suggestions'] || parsed[:suggestions] || [],
      token_usage: { input: usage['input_tokens'].to_i, output: usage['output_tokens'].to_i },
      raw:         parsed
    )
  rescue JSON::ParserError => e
    Rails.logger.error("[BudgetService] Failed to parse AI response: #{e.message}")
    ServiceResult.error("AI response was not valid JSON: #{e.message}")
  rescue => e
    Rails.logger.error("[BudgetService] Anthropic call failed: #{e.class}: #{e.message}")
    ServiceResult.error("AI request failed: #{e.message}")
  end

  def self.extract_text_from_anthropic_response(body)
    Array(body['content']).map { |c| c['text'].to_s }.join("\n").strip
  end

  def self.strip_markdown_fence(text)
    cleaned = text.to_s.strip
    if cleaned.start_with?('```')
      cleaned = cleaned.sub(/\A```(?:json)?\s*/, '').sub(/```\s*\z/, '')
    end
    cleaned.strip
  end

  # =========================================================================
  # SERVICE RESULT
  # =========================================================================

  class ServiceResult
    attr_reader :data, :message
    def initialize(success:, data: nil, message: nil)
      @success = success
      @data    = data
      @message = message
    end

    def self.ok(data = nil, **kwargs)
      payload = data || (kwargs.empty? ? nil : kwargs)
      new(success: true, data: payload)
    end

    def self.error(message)
      new(success: false, message: message)
    end

    def success?; @success; end
    def error?;   !@success; end
  end
end
