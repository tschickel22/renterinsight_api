# frozen_string_literal: true

module McpTools
  # Budget against actual from the posted ledger, by the same calculation the
  # Budget vs Actual report uses (BudgetService.calculate_variance).
  class BudgetVariance < Base
    tool_name 'budget_variance'
    title 'Budget against actual'
    description 'Compare a budget with the posted books for a month, a quarter, the year to date or the full ' \
                'year: every revenue and expense account with budget, actual and the difference, plus the biggest ' \
                'misses and wins in dollars. Leave id out to use the active budget for the current fiscal year. Unless ' \
                'the dealer lets AI apps see dealer cost, cost of goods sold accounts and net income are left out ' \
                '(costs_hidden says so).'
    input_schema(
      properties: {
        id: { type: 'string', description: 'budget:12; optional' },
        period: { type: 'string', enum: %w[month quarter ytd annual], description: 'Default ytd' },
        month: { type: 'string', description: 'For period month: a calendar month like 2026-09' },
        quarter: { type: 'integer', minimum: 1, maximum: 4, description: 'For period quarter: fiscal quarter' }
      }
    )
    read_only!

    def self.perform(ctx, id: nil, period: 'ytd', month: nil, quarter: nil)
      BudgetArea.require!(ctx, 'read')
      budget = id.present? ? BudgetArea.find!(ctx, id) : default_budget!(ctx)
      period = period.presence || 'ytd'
      fiscal_month = fiscal_month!(ctx, budget, month) if period == 'month'
      raise UserError, 'period quarter needs quarter (1 to 4).' if period == 'quarter' && quarter.blank?

      report = begin
        BudgetService.calculate_variance(budget, period: period, month: fiscal_month, quarter: quarter)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.error("[McpTools::BudgetVariance] budget #{budget.id}: #{e.message.first(300)}")
        raise UserError, 'Budget against actual could not be worked out for this budget. Open the Budget vs ' \
                         'Actual report in DealerTide.'
      end

      groups = visible_groups(ctx, report[:groups])
      rows = groups.flat_map { |g| g[:rows] }.map { |r| row(r) }
      payload = {
        budget: BudgetArea.summary(ctx, budget),
        period: report[:period].slice(:kind, :start_date, :end_date).merge(quarter: quarter).compact,
        net_income: (money_hash(report[:net_income]) if ctx.book_costs_visible?),
        costs_hidden: (COSTS_HIDDEN unless ctx.book_costs_visible?),
        subtotals: groups.to_h { |g| [g[:account_type], money_hash(g[:subtotal])] },
        biggest_misses: rows.select { |r| r[:impact].negative? }.sort_by { |r| r[:impact] }.first(5),
        biggest_wins: rows.select { |r| r[:impact].positive? }.sort_by { |r| -r[:impact] }.first(5),
        no_actuals_posted: rows.all? { |r| r[:actual].zero? },
        rows: rows
      }
      Base::Result.new(payload: payload.compact, count: 1)
    end

    COSTS_HIDDEN = 'Cost of goods sold accounts and net income are left out, and the expense subtotal leaves them ' \
                   'out, because actual cost of goods sold shows dealer cost. An admin can allow it under Settings, ' \
                   'Integrations, AI Apps, "Let AI apps see dealer cost and gross".'

    # Without the dealer cost switch, cost of goods sold rows go, and each
    # subtotal is worked out again from the rows that are left so it cannot
    # give them back by subtraction.
    def self.visible_groups(ctx, groups)
      return groups if ctx.book_costs_visible?

      cogs_ids = ctx.company.chart_of_accounts.where(sub_type: 'cost_of_goods_sold').pluck(:id).to_set
      groups.filter_map do |g|
        kept = g[:rows].reject { |r| cogs_ids.include?(r[:account_id]) }
        next if kept.empty?
        next g if kept.size == g[:rows].size

        b = kept.sum { |r| r[:budget_amount].to_d }
        a = kept.sum { |r| r[:actual_amount].to_d }
        g.merge(rows: kept, subtotal: { budget_amount: b, actual_amount: a, variance_amount: a - b,
                                        variance_percent: b.nonzero? ? (((a - b) / b) * 100).round(2).to_f : nil })
      end
    end

    # impact: dollars better (positive) or worse (negative) than budget, so
    # revenue under budget and spending over budget both read as negative.
    def self.row(r)
      diff = r[:actual_amount].to_d - r[:budget_amount].to_d
      impact = r[:account_type] == 'revenue' ? diff : -diff
      {
        gl_account_id: "gl_account:#{r[:account_id]}", account_number: r[:account_number], account_name: r[:account_name],
        account_type: r[:account_type], budget: BudgetArea.money(r[:budget_amount]), actual: BudgetArea.money(r[:actual_amount]),
        difference: BudgetArea.money(diff), percent: r[:variance_percent], impact: BudgetArea.money(impact), status: r[:status]
      }
    end

    def self.money_hash(h)
      return nil unless h

      { budget: BudgetArea.money(h[:budget_amount]), actual: BudgetArea.money(h[:actual_amount]),
        difference: BudgetArea.money(h[:variance_amount]), percent: h[:variance_percent] }
    end

    def self.default_budget!(ctx)
      year = BudgetArea.current_fiscal_year(ctx.company)
      candidates = BudgetArea.scope(ctx).where(fiscal_year: year, status: %w[active locked])
      budget = candidates.find_by(consolidation_type: 'consolidated') || candidates.find_by(location_id: nil) ||
               (candidates.first if candidates.one?)
      return budget if budget

      found = BudgetArea.scope(ctx).where(fiscal_year: year).pluck(:id, :name, :status)
      raise UserError, "No active budget for fiscal year #{year}." if found.empty?

      raise UserError, 'Say which budget: ' + found.map { |i, n, s| "budget:#{i} #{n} (#{s})" }.join('; ')
    end

    def self.fiscal_month!(ctx, budget, month)
      date = begin
        Date.strptime(month.to_s, '%Y-%m')
      rescue Date::Error
        raise UserError, 'For period month, give month like 2026-09.'
      end
      first, last = BudgetService.fiscal_year_range(ctx.company, budget.fiscal_year)
      unless date.between?(first, last)
        raise UserError, "#{month} is outside fiscal year #{budget.fiscal_year} (#{first.strftime('%b %Y')} to " \
                         "#{last.strftime('%b %Y')})."
      end

      BudgetService.calendar_to_fiscal_month(date.month, BudgetArea.start_month(ctx.company))
    end
  end
end
