# frozen_string_literal: true

module McpTools
  # Counts, not records: how many open leads each person (and each status)
  # has, how many have gone quiet, and how many have no next step scheduled.
  # Cheap to call first, so the AI can size the problem before it lists
  # anyone, and it spends one record of the daily budget per row it returns.
  class LeadFollowUpGaps < Base
    tool_name 'lead_follow_up_gaps'
    title 'Leads with no next step'
    description 'Counts of open leads by owner and by status: how many have had no activity in quiet_days ' \
                '(default 14), how many have no follow-up scheduled, and how many follow-ups are overdue. ' \
                'Closed statuses are left out. Use it before list_leads to see where follow-up is slipping.'
    input_schema(
      properties: {
        quiet_days: { type: 'integer', minimum: 1, maximum: 365 },
        owner: { type: 'string', description: '"me" or a user id; leave out for everyone you can see' }
      }
    )
    read_only!

    def self.perform(ctx, quiet_days: 14, owner: nil)
      days = (quiet_days.presence || 14).to_i.clamp(1, 365)
      rel = ListLeads.open_statuses(ctx, Records.new(ctx).scope('lead'))
      rel = rel.where(owner_id: owner == 'me' ? ctx.user.id : owner.to_i) if owner.present?

      ctx.row_limit(1)
      open_follow_up = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, ListLeads::OPEN_ACTIVITY_STATUSES])
        SELECT 1 FROM lead_activities la WHERE la.lead_id = leads.id AND la.status IN (?) AND la.activity_type <> 'note'
      SQL
      overdue = ActiveRecord::Base.sanitize_sql_array(["#{open_follow_up} AND la.due_date < ?", Time.current])
      quiet = ActiveRecord::Base.sanitize_sql_array(['COALESCE(leads.last_activity_at, leads.created_at) < ?', days.days.ago])
      columns = [
        'COUNT(*)',
        "COUNT(*) FILTER (WHERE #{quiet})",
        "COUNT(*) FILTER (WHERE NOT EXISTS (#{open_follow_up}))",
        "COUNT(*) FILTER (WHERE EXISTS (#{overdue}))"
      ].map { |c| Arel.sql(c) }

      row = ->(counts) { %i[open_leads quiet no_follow_up overdue_follow_up].zip(counts).to_h }
      by_owner = rel.group(:owner_id).pluck(:owner_id, *columns).map do |owner_id, *counts|
        { owner: owner_id ? (ctx.user_names[owner_id] || "User #{owner_id}") : 'Unassigned', owner_id: owner_id }.merge(row.call(counts))
      end
      labels = ctx.company.lead_statuses.pluck(:key, :label).to_h
      by_status = rel.group(:status).pluck(:status, *columns).map do |status, *counts|
        { status: status, label: labels[status] }.merge(row.call(counts))
      end
      total = row.call(rel.pick(*columns))

      Base::Result.new(payload: {
        quiet_days: days, totals: total,
        by_owner: by_owner.sort_by { |r| -r[:no_follow_up] },
        by_status: by_status.sort_by { |r| -r[:open_leads] }
      }, count: by_owner.size + by_status.size)
    end
  end
end
