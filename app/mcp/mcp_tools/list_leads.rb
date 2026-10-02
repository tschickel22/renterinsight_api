# frozen_string_literal: true

module McpTools
  class ListLeads < ListTool
    tool_name 'list_leads'
    title 'List leads'
    description 'List open leads (not yet converted), newest first unless sort says otherwise. Filter by status ' \
                'key, by owner ("me", "unassigned" or a user id from get_reference_data), by when they came in, ' \
                'or by a name/email/phone search. sort=stale lists the leads nobody has touched longest. ' \
                'Closed statuses (lost, junk, do not contact) are left out unless a status is asked for or ' \
                'include_closed=true. quiet_days and no_follow_up find leads that have fallen through the cracks.'
    input_schema(
      properties: {
        status: { type: 'string', description: 'A lead status key from get_reference_data' },
        owner: { type: 'string', description: '"me", "unassigned", or a user id' },
        created_after: { type: 'string', description: 'ISO date, e.g. 2026-09-01' },
        query: { type: 'string', description: 'Name, email or phone contains' },
        sort: { type: 'string', enum: %w[newest stale recent_activity] },
        quiet_days: { type: 'integer', minimum: 1, description: 'No activity in at least this many days' },
        no_follow_up: { type: 'boolean', description: 'Only leads with no open call, task or reminder scheduled' },
        include_closed: { type: 'boolean' },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: nil, owner: nil, created_after: nil, query: nil, sort: 'newest', quiet_days: nil,
                     no_follow_up: false, include_closed: false, limit: 20)
      records = Records.new(ctx)
      rel = records.scope('lead')
      rel = rel.where(id: records.search('lead', query, 500).map(&:id)) if query.present?
      if status.present?
        rel = rel.where(status: status)
      elsif !include_closed
        rel = open_statuses(ctx, rel)
      end
      rel = quiet_since(rel, quiet_days) if quiet_days.present?
      rel = without_follow_up(rel) if no_follow_up
      case owner.to_s
      when '' then nil
      when 'me' then rel = rel.where(owner_id: ctx.user.id)
      when 'unassigned' then rel = rel.where(owner_id: nil)
      else rel = rel.where(owner_id: owner.to_i)
      end
      if (date = parse_date(created_after, 'created_after'))
        rel = rel.where('leads.created_at >= ?', date.beginning_of_day)
      end
      rel = case sort
            when 'stale' then rel.order(Arel.sql('leads.last_activity_at ASC NULLS FIRST'))
            when 'recent_activity' then rel.order(Arel.sql('leads.last_activity_at DESC NULLS LAST'))
            else rel.order(created_at: :desc)
            end
      listing(ctx, 'lead', rel, limit)
    end

    # The company's closed statuses are the ones its lead status settings
    # exclude from the working pipeline (lost, junk, do not contact...).
    def self.open_statuses(ctx, rel)
      closed = ctx.company.lead_statuses.excluded.pluck(:key)
      closed.any? ? rel.where('leads.status IS NULL OR leads.status NOT IN (?)', closed) : rel
    end

    def self.quiet_since(rel, days)
      rel.where('COALESCE(leads.last_activity_at, leads.created_at) < ?', days.to_i.days.ago)
    end

    # A follow-up is any open lead activity other than a note, which is what
    # the lead page and My Tasks show as "next step".
    def self.without_follow_up(rel)
      rel.where.not(id: LeadActivity.where(status: OPEN_ACTIVITY_STATUSES).where.not(activity_type: 'note').select(:lead_id))
    end

    OPEN_ACTIVITY_STATUSES = %w[pending in_progress].freeze
  end
end
