# frozen_string_literal: true

module McpTools
  # Builds a budget and saves it as a DRAFT. A draft counts for nothing until
  # a person activates it in DealerTide; there is no activate tool.
  class CreateBudgetDraft < Base
    tool_name 'create_budget_draft'
    title 'Draft a budget'
    description 'Create a budget as a DRAFT, either from lines you give (revenue and expense accounts from ' \
                'budget_history or the chart of accounts) or by copying a prior fiscal year (its budget if there ' \
                'is one, otherwise its actuals) with a growth percent. Show the user the numbers before saving. ' \
                'It does not count until a person activates it in DealerTide; this connector cannot activate, ' \
                'lock or approve budgets.'
    input_schema(
      properties: {
        name: { type: 'string', description: 'Default "<year> Budget"' },
        fiscal_year: { type: 'integer' },
        location_id: { type: 'integer', description: 'Leave out for a company-wide budget' },
        description: { type: 'string' },
        lines: BudgetArea::LINE_SCHEMA,
        copy_from_fiscal_year: { type: 'integer', description: 'Instead of lines: start from this fiscal year' },
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

          copy!(ctx, year, location_id, name, copy_from_fiscal_year, growth_percent)
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

    def self.copy!(ctx, year, location_id, name, source_year, growth_percent)
      result = BudgetService.create_from_prior_year(
        company: ctx.company, source_year: BudgetArea.check_fiscal_year!(source_year), target_year: year,
        location_id: location_id, growth_percent: growth_percent.to_f, name: name, created_by: ctx.user
      )
      raise UserError, result.message.to_s.gsub(/\s*[\u2013\u2014]\s*/, ", ") unless result.success?

      budget = result.data
      budget.update_column(:metadata, budget.metadata.merge('created_via' => 'ai_connector'))
      budget
    end
  end
end
