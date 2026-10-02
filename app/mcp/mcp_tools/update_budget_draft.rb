# frozen_string_literal: true

module McpTools
  # Changes a DRAFT budget: rename it, set lines, take lines out. Active,
  # locked, archived and consolidated budgets are refused.
  class UpdateBudgetDraft < Base
    tool_name 'update_budget_draft'
    title 'Change a draft budget'
    description 'Change a DRAFT budget: rename it, set or replace the amounts on some accounts (other lines stay ' \
                'as they are), or remove accounts. Only drafts can be changed here. Show the user the change ' \
                'before making it.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'budget:12' },
        name: { type: 'string' },
        lines: BudgetArea::LINE_SCHEMA,
        remove_gl_account_ids: { type: 'array', items: { type: 'string' }, description: 'gl_account:45 lines to take out' }
      },
      required: ['id']
    )
    writes!(destructive: true)

    NOT_DRAFT = 'Only draft budgets can be changed here; revert it to draft in DealerTide first.'

    def self.perform(ctx, id:, name: nil, lines: nil, remove_gl_account_ids: nil)
      BudgetArea.require!(ctx, 'update')
      budget = BudgetArea.find!(ctx, id)
      raise UserError, NOT_DRAFT unless BudgetArea.draft_editable?(budget)
      if name.blank? && lines.blank? && remove_gl_account_ids.blank?
        raise UserError, 'Nothing to change: give name, lines or remove_gl_account_ids.'
      end

      parsed = lines.present? ? BudgetArea.parse_lines!(ctx, lines) : {}
      remove_ids = Array(remove_gl_account_ids).map { |v| BudgetArea.parse_id(v, 'gl_account') }
      if (overlap = parsed.keys.map(&:id) & remove_ids).any?
        raise UserError, "gl_account:#{overlap.first} is both set and removed. Pick one."
      end

      before = BudgetArea.snapshot(budget)
      Budget.transaction do
        budget.update!(name: name.to_s.strip.first(200)) if name.present?
        BudgetArea.write_lines!(budget, parsed)
        budget.budget_lines.where(chart_of_account_id: remove_ids).destroy_all if remove_ids.any?
      end
      after = BudgetArea.snapshot(budget)
      ctx.record_change(action: 'updated', record: budget, before: before, after: after) unless before == after

      detail = BudgetArea.detail(ctx, budget)
      Base::Result.new(payload: {
        updated: detail.slice(:id, :name, :status, :url, :net_income)
                       .merge(subtotals: detail[:groups].to_h { |g| [g[:group], g[:subtotal][:annual]] }),
        lines_set: parsed.size, lines_removed: (before['lines'].keys - after['lines'].keys).size,
        next_step: BudgetArea.activation_note(ctx, budget)
      }, count: 1)
    end
  end
end
