# frozen_string_literal: true

module McpTools
  # Builds a budget and saves it as a DRAFT. A draft counts for nothing until
  # a person activates it in DealerTide; there is no activate tool.
  class CreateBudgetDraft < Base
    tool_name 'create_budget_draft'
    title 'Draft a budget'
    description 'Create a budget as a DRAFT, either from lines you give (revenue and expense accounts from ' \
                'budget_history or the chart of accounts; balance sheet accounts are refused) or by copying a prior ' \
                'fiscal year (its budget if there is one, otherwise its posted revenue and expenses) with a growth ' \
                'percent. A copy takes revenue and expense accounts only, and is refused when that year has no ' \
                'revenue or expense activity: check budget_history first and build from lines when it is empty. ' \
                'Show the user the numbers before saving. ' \
                'It does not count until a person activates it in DealerTide; this connector cannot activate, ' \
                'lock or approve budgets.'
    input_schema(
      properties: {
        name: { type: 'string', description: 'Default "<year> Budget"' },
        fiscal_year: { type: 'integer' },
        location_id: { type: 'integer', description: 'Leave out for a company-wide budget' },
        description: { type: 'string' },
        lines: BudgetArea::LINE_SCHEMA,
        copy_from_fiscal_year: { type: 'integer', description: 'Instead of lines: start from this fiscal year (revenue and ' \
                                                                       'expense accounts only)' },
        growth_percent: { type: 'number', description: 'With copy_from_fiscal_year, e.g. 5 for 5 percent' }
      },
      required: ['fiscal_year']
    )
    writes!(destructive: false)

    def self.perform(ctx, fiscal_year:, name: nil, location_id: nil, description: nil, lines: nil,
                     copy_from_fiscal_year: nil, growth_percent: nil)
      BudgetArea.require!(ctx, 'create')
      company = ctx.company
      year = BudgetArea.check_fiscal_year!(fiscal_year)
      location_id = location!(ctx, location_id)
      name = name.to_s.strip.first(200).presence || "#{year} Budget"
      if company.budgets.exists?(fiscal_year: year, location_id: location_id, name: name)
        raise UserError, "A budget named #{name.inspect} already exists for #{year} there. Pick another name, or " \
                         'change that one with update_budget_draft if it is a draft.'
      end

      budget =
        if copy_from_fiscal_year.present?
          raise UserError, 'Give either lines or copy_from_fiscal_year, not both.' if lines.present?

          copy!(ctx, year, location_id, name, description, copy_from_fiscal_year, growth_percent)
        else
          raise UserError, 'Give lines, or copy_from_fiscal_year to start from a prior year.' if lines.blank?

          from_lines!(ctx, year, location_id, name, description, lines)
        end
      ctx.record_change(action: 'created', record: budget, after: BudgetArea.snapshot(budget))

      detail = BudgetArea.detail(ctx, budget)
      Base::Result.new(payload: {
        draft: detail.slice(:id, :name, :fiscal_year, :location, :status, :url, :month_labels, :net_income)
                     .merge(subtotals: detail[:groups].to_h { |g| [g[:group], g[:subtotal][:annual]] },
                            line_count: detail[:groups].sum { |g| g[:lines].size }),
        source: budget.metadata['source_label'],
        next_step: BudgetArea.activation_note(ctx, budget)
      }, count: 1)
    end

    def self.location!(ctx, location_id)
      if location_id.present?
        raise UserError, "No location #{location_id} that you have access to." unless ctx.location_allowed?(location_id)

        return location_id.to_i
      end
      return nil if ctx.location_ids.nil?

      raise UserError, 'You can only budget your own locations: give location_id (see get_reference_data).'
    end

    def self.from_lines!(ctx, year, location_id, name, description, lines)
      parsed = BudgetArea.parse_lines!(ctx, lines)
      Budget.transaction do
        budget = ctx.company.budgets.create!(
          name: name, fiscal_year: year, location_id: location_id, description: description,
          budget_type: 'annual', status: 'draft', consolidation_type: 'standalone', created_by_id: ctx.user.id,
          metadata: { 'source' => 'ai_connector', 'source_label' => 'lines' }
        )
        BudgetArea.write_lines!(budget, parsed)
        budget
      end
    end

    # Copies only revenue and expense accounts. BudgetService.create_from_prior_year
    # (the app's copy) takes every account with entries, so a year whose only
    # activity was a bank transfer became a "budget" of two cash accounts. A
    # year with no profit and loss activity is refused and nothing is saved.
    def self.copy!(ctx, year, location_id, name, description, source_year, growth_percent)
      company = ctx.company
      source_year = BudgetArea.check_fiscal_year!(source_year)
      months_by_account, source_label, coverage = copy_source(company, source_year, location_id)
      if months_by_account.empty?
        raise UserError, "No revenue or expense activity in fiscal year #{source_year}, so there is nothing to " \
                         'copy and nothing was saved. Build the budget from the owner\'s own numbers with lines instead.'
      end

      growth = 1 + (growth_percent.to_f / 100)
      parsed = months_by_account.to_h do |account, months|
        [account, [months.map { |m| (m * growth.to_d).round(2) }, nil]]
      end
      Budget.transaction do
        budget = company.budgets.create!(
          name: name, fiscal_year: year, location_id: location_id, description: description, budget_type: 'annual',
          status: 'draft', consolidation_type: 'standalone', created_by_id: ctx.user.id,
          metadata: { 'source' => 'prior_year', 'source_year' => source_year, 'source_label' => source_label,
                      'growth_percent' => growth_percent.to_f, 'created_via' => 'ai_connector',
                      'data_coverage' => coverage&.deep_stringify_keys, 'annualized' => source_label == 'actuals_annualized' }.compact
        )
        BudgetArea.write_lines!(budget, parsed)
        budget
      end
    end

    # [{ account => [12 BigDecimals] }, source label, coverage]. The source
    # year's budget if it has revenue or expense lines, otherwise its posted
    # revenue and expenses, annualized when only some months have any.
    def self.copy_source(company, source_year, location_id)
      source_budget = company.budgets.standalone.by_fiscal_year(source_year).find_by(location_id: location_id)
      if source_budget
        rows = source_budget.budget_lines.includes(:chart_of_account).filter_map do |line|
          account = line.chart_of_account
          next unless copyable?(account)

          months = (1..12).map { |m| line.month_amount(m).to_d }
          [account, months] unless months.all?(&:zero?)
        end
        return [rows.to_h, "budget:#{source_budget.id}", nil] if rows.any?
      end

      actuals = BudgetService.actuals_by_month(company, source_year, location_id: location_id)
      accounts = company.chart_of_accounts.where(id: actuals.keys).select { |a| copyable?(a) }
      raw = accounts.to_h { |a| [a.id, actuals[a.id]] }.reject { |_, monthly| monthly.values.all?(&:zero?) }
      return [{}, nil, nil] if raw.empty?

      months_with_data = (1..12).select { |m| raw.values.any? { |monthly| monthly[m].to_d.nonzero? } }
      coverage = { months_with_data: months_with_data, coverage_count: months_with_data.size }
      partial = months_with_data.size < 12
      raw = BudgetService.annualize_partial_data(raw, coverage) if partial
      by_id = accounts.index_by(&:id)
      rows = raw.to_h { |id, monthly| [by_id[id], (1..12).map { |m| monthly[m].to_d }] }
      [rows, partial ? 'actuals_annualized' : 'actuals_full_year', coverage]
    end

    def self.copyable?(account)
      account && BudgetArea::PL_TYPES.include?(account.account_type) && account.is_active && !account.is_header
    end
  end
end
