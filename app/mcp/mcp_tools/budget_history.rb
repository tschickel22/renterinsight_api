# frozen_string_literal: true

module McpTools
  # Real numbers to plan from: a fiscal year's posted revenue and expenses by
  # account and month, with how many months have any entries at all.
  class BudgetHistory < Base
    tool_name 'budget_history'
    title 'Actual revenue and expenses by month'
    description "A fiscal year's actual revenue and expenses from the posted books, by account and month (fiscal " \
                'order, month_labels names them), with how many months have entries. Use it to build or check a ' \
                'budget. Company-wide figures. Most dealers have little or no history yet; coverage says so.'
    input_schema(
      properties: { fiscal_year: { type: 'integer', description: 'Default: last fiscal year' } }
    )
    read_only!

    def self.perform(ctx, fiscal_year: nil)
      BudgetArea.require!(ctx, 'read')
      ctx.row_limit(1) # stops here once the daily record budget is spent
      company = ctx.company
      year = fiscal_year.present? ? BudgetArea.check_fiscal_year!(fiscal_year) : BudgetArea.current_fiscal_year(company) - 1
      coverage = BudgetService.data_coverage(company, year)
      actuals = BudgetService.actuals_by_month(company, year)

      accounts = company.chart_of_accounts.where(id: actuals.keys, account_type: BudgetArea::PL_TYPES)
                        .order(:account_number).to_a
      rows = accounts.map { |a| [a, (1..12).map { |m| actuals[a.id][m] }] }
                     .reject { |_, months| months.all?(&:zero?) }
      groups, net = BudgetArea.pl_groups(rows)

      payload = {
        fiscal_year: year, month_labels: BudgetArea.month_labels(company, year),
        coverage: coverage.slice(:months_with_data, :coverage_count, :first_data_month, :last_data_month, :is_partial, :is_empty),
        note: coverage_note(coverage),
        groups: groups, net_income: net
      }
      Base::Result.new(payload: payload, count: rows.size)
    end

    def self.coverage_note(coverage)
      return 'No posted entries in this fiscal year. Build the budget from the owner\'s own numbers instead.' if coverage[:is_empty]
      return nil unless coverage[:is_partial]

      "Only #{coverage[:coverage_count]} of 12 months have entries (#{coverage[:first_data_month]} to " \
        "#{coverage[:last_data_month]}). Do not treat missing months as zero sales."
    end
  end
end
