# frozen_string_literal: true

module McpTools
  class ListNurtureSequences < ListTool
    tool_name 'list_nurture_sequences'
    title 'List nurture sequences'
    description 'List nurture sequences with their steps (email, text, wait, task, call, and the days between) ' \
                'and how many people are in each now (running, paused, completed). Use the sequence id with ' \
                'enroll_in_nurture. Read only.'
    input_schema(
      properties: {
        include_inactive: { type: 'boolean' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, include_inactive: false, limit: 20)
      ctx.authorize!('crm', 'read')
      rel = ctx.company.nurture_sequences
      rel = rel.where(is_active: true) unless include_inactive
      rows = rel.order(:name).limit(ctx.row_limit(limit)).includes(:nurture_steps).to_a
      counts = NurtureEnrollment.where(nurture_sequence_id: rows.map(&:id)).group(:nurture_sequence_id, :status).count
      items = rows.map do |s|
        {
          id: "sequence:#{s.id}", name: s.name, description: s.description, active: s.is_active,
          stops_on_reply: s.stop_on_reply, stops_on_conversion: s.stop_on_conversion,
          steps: s.nurture_steps.sort_by(&:position).map do |st|
            { type: st.step_type, wait_days: st.wait_days&.to_f, subject: st.subject.presence }.compact
          end,
          enrolled: NurtureEnrollment::STATUSES.to_h { |status| [status, counts[[s.id, status]] || 0] }
        }
      end
      Base::Result.new(payload: { count: items.size, items: items }, count: items.size)
    end
  end
end
