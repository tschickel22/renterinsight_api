# frozen_string_literal: true

module McpTools
  # Budgets through the connector: read any budget the person can see, read
  # last year's actuals to plan from, and build or revise DRAFT budgets.
  # Activating, locking and approving stay with a person in DealerTide; there
  # is no tool for them.
  #
  # Same rules as BudgetsController: the Accounting plan module, the
  # 'budgets' permission, and location users see their locations' budgets
  # plus the company-wide ones.
  module BudgetArea
    MODULE_KEY = 'finance.accounting'
    PL_TYPES = %w[revenue expense].freeze
    MAX_AMOUNT = 10_000_000_000

    LINE_SCHEMA = {
      type: 'array',
      description: 'One entry per account. Either months (12 amounts in fiscal order, starting with the first month ' \
                   'of the fiscal year; get_budget and budget_history show the month labels) or annual plus ' \
                   'seasonality ("even", or 12 weights such as [2,2,3,4,5,5,5,5,4,3,2,2]). Amounts are positive in ' \
                   "the account's natural direction: revenue as income, expenses as spending.",
      items: {
        type: 'object',
        properties: {
          gl_account_id: { type: 'string', description: 'gl_account:45 from budget_history or get_budget' },
          months: { type: 'array', items: { type: 'number' }, minItems: 12, maxItems: 12 },
          annual: { type: 'number' },
          seasonality: { description: '"even" or an array of 12 weights' },
          notes: { type: 'string', description: 'How the number was worked out, kept on the line' }
        },
        required: ['gl_account_id']
      }
    }.freeze

    module_function

    # --- access -----------------------------------------------------------

    def require!(ctx, action)
      unless ModuleAccessService.new(ctx.company).has_module?(MODULE_KEY)
        raise Denied, "Accounting is not part of this account's plan, so I cannot read or build budgets."
      end

      ctx.authorize!('budgets', action)
    end

    def scope(ctx)
      rel = ctx.company.budgets
      ids = ctx.location_ids
      return rel if ids.nil?

      rel.where(location_id: ids).or(rel.where(location_id: nil))
    end

    def find!(ctx, id)
      scope(ctx).find(parse_id(id, 'budget'))
    end

    def parse_id(value, type)
      text = value.to_s.strip
      text = text.delete_prefix("#{type}:")
      raise UserError, "Ids look like #{type}:12, not #{value.inspect}." unless text.match?(/\A\d+\z/)

      text.to_i
    end

    def url(ctx, budget)
      ctx.app_url("/accounting/budgets/#{budget.id}")
    end

    # --- fiscal calendar --------------------------------------------------

    def start_month(company)
      BudgetService.fiscal_year_start_month(company)
    end

    def current_fiscal_year(company)
      today = Date.current
      today.month >= start_month(company) ? today.year : today.year - 1
    end

    def month_labels(company, fiscal_year)
      first = Date.new(fiscal_year, start_month(company), 1)
      (0..11).map { |i| (first >> i).strftime('%b %Y') }
    end

    def check_fiscal_year!(value)
      year = value.to_i
      raise UserError, 'fiscal_year must be a year like 2027.' unless year.between?(2020, 2100)

      year
    end

    # --- shaping ----------------------------------------------------------

    def group_key(account)
      return 'revenue' if account.account_type == 'revenue'
      return 'cost_of_goods_sold' if account.account_type == 'expense' && account.sub_type == 'cost_of_goods_sold'
      return 'expense' if account.account_type == 'expense'

      'other'
    end

    GROUP_TITLES = {
      'revenue' => 'Revenue', 'cost_of_goods_sold' => 'Cost of goods sold', 'expense' => 'Expenses',
      'other' => 'Other accounts (balance sheet, not part of profit)'
    }.freeze

    def money(value)
      value.to_d.round(2).to_f
    end

    def account_ref(account)
      { gl_account_id: "gl_account:#{account.id}", account_number: account.account_number, account_name: account.name }
    end

    # rows: [[account, [12 amounts]]]. Groups with subtotals, and net income
    # as revenue less cost of goods sold less expenses.
    def pl_groups(rows)
      grouped = rows.group_by { |account, _| group_key(account) }
      groups = GROUP_TITLES.keys.filter_map do |key|
        group_rows = grouped[key]
        next unless group_rows

        lines = group_rows.map do |account, months|
          account_ref(account).merge(months: months.map { |m| money(m) }, annual: money(months.sum(&:to_d)))
        end
        subtotal = (0..11).map { |i| group_rows.sum { |_, months| months[i].to_d } }
        { group: key, title: GROUP_TITLES[key], lines: lines,
          subtotal: { months: subtotal.map { |m| money(m) }, annual: money(subtotal.sum) } }
      end
      by_key = groups.index_by { |g| g[:group] }
      net = (0..11).map do |i|
        %w[revenue cost_of_goods_sold expense].sum do |key|
          amount = by_key.dig(key, :subtotal, :months, i).to_d
          key == 'revenue' ? amount : -amount
        end
      end
      [groups, { months: net.map { |m| money(m) }, annual: money(net.sum) }]
    end

    # Revenue, costs and net income, never one sum of all lines: adding
    # revenue to costs gave a "total budgeted" that meant nothing.
    def pl_totals(budget)
      sums = Hash.new(0.to_d)
      budget.budget_lines.includes(:chart_of_account).each do |line|
        sums[group_key(line.chart_of_account)] += line.annual_total.to_d
      end
      { revenue: money(sums['revenue']), cost_of_goods_sold: money(sums['cost_of_goods_sold']),
        expense: money(sums['expense']),
        net_income: money(sums['revenue'] - sums['cost_of_goods_sold'] - sums['expense']) }
    end

    def summary(ctx, budget)
      {
        id: "budget:#{budget.id}", name: budget.name, fiscal_year: budget.fiscal_year, status: budget.status,
        location: budget.location_name, consolidated: budget.consolidated?,
        editable_here: draft_editable?(budget),
        totals: pl_totals(budget),
        updated_at: budget.updated_at&.iso8601, url: url(ctx, budget)
      }
    end

    def detail(ctx, budget)
      lines = budget.budget_lines.includes(:chart_of_account).sort_by { |l| l.chart_of_account.account_number.to_s }
      groups, net = pl_groups(lines.map { |l| [l.chart_of_account, (1..12).map { |m| l.month_amount(m).to_d }] })
      summary(ctx, budget).merge(
        description: budget.description, notes: budget.notes,
        approved_at: budget.approved_at&.iso8601, locked_at: budget.locked_at&.iso8601,
        month_labels: month_labels(ctx.company, budget.fiscal_year),
        groups: groups, net_income: net
      )
    end

    def draft_editable?(budget)
      budget.draft? && budget.standalone?
    end

    # --- lines in ---------------------------------------------------------

    # Parses the lines argument into { account => [12 BigDecimals, notes] },
    # raising UserError on anything the app itself would not accept.
    def parse_lines!(ctx, lines)
      raise UserError, 'lines must be a list of accounts with amounts.' unless lines.is_a?(Array)
      raise UserError, 'Give at most 300 lines at a time.' if lines.size > 300

      seen = {}
      lines.each_with_index.to_h do |raw, index|
        line = raw.respond_to?(:to_h) ? raw.to_h.stringify_keys : {}
        account = postable_pl_account!(ctx, line['gl_account_id'])
        raise UserError, "#{account.account_number} #{account.name} is listed twice." if seen[account.id]

        seen[account.id] = true
        [account, [months_for!(line, index), line['notes'].to_s.strip.first(1000).presence]]
      end
    end

    def postable_pl_account!(ctx, value)
      id = parse_id(value, 'gl_account')
      account = ctx.company.chart_of_accounts.find_by(id: id)
      raise UserError, "No account gl_account:#{id} in this company's chart of accounts." unless account
      unless account.is_active && !account.is_header
        raise UserError, "#{account.account_number} #{account.name} is a header or inactive account; budget the accounts under it."
      end
      unless PL_TYPES.include?(account.account_type)
        raise UserError, "#{account.account_number} #{account.name} is a #{account.account_type} account. Budgets " \
                         'here cover revenue and expense accounts only.'
      end

      account
    end

    def months_for!(line, index)
      where = "Line #{index + 1}"
      if line['months'].present?
        months = Array(line['months'])
        raise UserError, "#{where}: months needs exactly 12 amounts." unless months.size == 12

        return months.map { |m| amount!(m, where) }
      end
      raise UserError, "#{where}: give months (12 amounts) or annual." if line['annual'].nil?

      spread(amount!(line['annual'], where), line['seasonality'], where)
    end

    def amount!(value, where)
      number = Float(value.to_s, exception: false)
      raise UserError, "#{where}: #{value.inspect} is not an amount." unless number&.finite? && number.abs < MAX_AMOUNT

      number.to_d.round(2)
    end

    # Weighted spread that adds back to the annual figure to the cent: the
    # rounding remainder lands on the last month.
    def spread(annual, seasonality, where)
      weights =
        if seasonality.blank? || seasonality.to_s == 'even'
          Array.new(12, 1)
        else
          list = Array(seasonality)
          raise UserError, "#{where}: seasonality is \"even\" or 12 weights." unless list.size == 12

          list.map { |w| amount!(w, where) }
        end
      total = weights.sum(&:to_d)
      raise UserError, "#{where}: seasonality weights must add up to more than zero." unless total.positive?
      raise UserError, "#{where}: seasonality weights cannot be negative." if weights.any?(&:negative?)

      months = weights.map { |w| (annual * w.to_d / total).round(2) }
      months[11] += annual - months.sum
      months
    end

    def write_lines!(budget, parsed)
      parsed.each do |account, (months, notes)|
        line = budget.budget_lines.find_or_initialize_by(chart_of_account_id: account.id)
        months.each_with_index { |amount, i| line.set_month_amount(i + 1, amount) }
        line.notes = notes if notes
        line.save!
      end
    end

    # --- undo ---------------------------------------------------------------

    # What Undo compares and restores: the name, status and every line's
    # twelve months, formatted the same way every time.
    def snapshot(budget)
      lines = budget.budget_lines.reload.to_h do |l|
        [l.chart_of_account_id.to_s, (1..12).map { |m| format('%.2f', l.month_amount(m).to_d) }]
      end
      { 'name' => budget.name, 'status' => budget.status, 'lines' => lines.sort.to_h }
    end

    def handles?(record)
      record.is_a?(Budget)
    end

    def label(record_type)
      'draft budget' if record_type == 'Budget'
    end

    # One line for the Connected Apps list, not every month of every line.
    def describe_change(change)
      return "Created draft budget #{change.record_id}" if change.action == 'created'

      before = change.before['lines'] || {}
      after = change.after['lines'] || {}
      changed = (before.keys | after.keys).count { |k| before[k] != after[k] }
      renamed = change.before['name'] != change.after['name'] ? ", renamed to #{change.after['name'].inspect}" : ''
      "Edited draft budget #{change.record_id}: #{changed} #{changed == 1 ? 'line' : 'lines'} changed#{renamed}"
    end

    def undo_created(change, record)
      unless record.draft? && Undo.same_value?(snapshot(record), change.after)
        return Undo.skipped('The budget was activated or edited since. Delete or archive it in DealerTide if it should go.')
      end

      record.destroy!
      Undo.done('Draft budget deleted.')
    end

    def undo_updated(change, record)
      unless record.draft?
        return Undo.skipped('The budget is no longer a draft. Change it back by hand in DealerTide.')
      end
      unless Undo.same_value?(snapshot(record), change.after)
        return Undo.skipped('The budget was edited again since. Left as it is.')
      end

      before = change.before
      Budget.transaction do
        record.update!(name: before['name'])
        wanted = before['lines'] || {}
        record.budget_lines.where.not(chart_of_account_id: wanted.keys.map(&:to_i)).destroy_all
        wanted.each do |account_id, months|
          line = record.budget_lines.find_or_initialize_by(chart_of_account_id: account_id.to_i)
          months.each_with_index { |amount, i| line.set_month_amount(i + 1, amount.to_d) }
          line.save!
        end
      end
      Undo.done('Draft budget restored to how it was before the edit.')
    end

    def activation_note(ctx, budget)
      "Saved as a DRAFT. It does not count until someone reviews and activates it in DealerTide: open #{url(ctx, budget)}, " \
        'check the lines, then click Activate. Tell the user this; I cannot activate, lock or approve budgets.'
    end

    # Last, because the tools read LINE_SCHEMA and the helpers above while
    # they load.
    READ_TOOLS = [ListBudgets, GetBudget, BudgetVariance, BudgetHistory].freeze
    WRITE_TOOLS = [CreateBudgetDraft, UpdateBudgetDraft].freeze
    PROMPTS = [McpPrompts::BudgetCheck, McpPrompts::BudgetFromLastYear].freeze
  end
end
