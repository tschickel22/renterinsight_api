# frozen_string_literal: true

module McpTools
  # Mirrors the app's move_stage: validated stage, stage history row, and the
  # close date stamped when the deal is won.
  class UpdateDealStage < Base
    tool_name 'update_deal_stage'
    title 'Move a deal to another stage'
    description "Move a deal to another pipeline stage (keys from get_reference_data). Moving to a won stage " \
                'can trigger the same follow-on work as in the app (marking the home sold, accounting entries), ' \
                'so confirm with the user first.'
    input_schema(
      properties: {
        id: { type: 'string', description: 'deal:7' },
        stage: { type: 'string' },
        note: { type: 'string', description: 'Why, saved with the stage history' }
      },
      required: %w[id stage]
    )
    writes!

    def self.perform(ctx, id:, stage:, note: nil)
      records = Records.new(ctx)
      type, deal = records.find(id)
      raise UserError, 'That id is not a deal.' unless type == 'deal'

      ctx.authorize!('deals', 'update')
      key = stage.to_s.strip.downcase
      unless ctx.company.valid_pipeline_stage?(key)
        raise UserError, "Unknown stage #{stage.inspect}. Valid: #{ctx.company.pipeline_stage_keys.join(', ')}."
      end

      from = deal.stage
      closed_before = deal.actual_close_date
      Deal.transaction do
        deal.update!(stage: key)
        deal.deal_stage_histories.create!(stage: key, previous_stage: from, changed_by_id: ctx.user.id, notes: note)
      end
      deal.update_column(:actual_close_date, Date.current) if deal.stage_is_won? && deal.actual_close_date.blank?
      ctx.record_change(action: 'updated', record: deal,
                        before: { stage: from, actual_close_date: closed_before&.iso8601 },
                        after: { stage: key, actual_close_date: deal.actual_close_date&.iso8601 })

      Base::Result.new(payload: { updated: records.summary('deal', deal.reload), from: from, to: key }, count: 1)
    end
  end
end
