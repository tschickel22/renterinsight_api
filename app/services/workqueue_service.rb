# frozen_string_literal: true

require 'digest'

class WorkqueueService
  QUEUES = {
    'engagement_opened_today'     => :engagement_opened_today,
    'engagement_opened_week'      => :engagement_opened_week,
    'engagement_clicked_today'    => :engagement_clicked_today,
    'engagement_hot_reopeners'    => :engagement_hot_reopeners,
    'activity_tasks_today'        => :activity_tasks_today,
    'activity_tasks_week'         => :activity_tasks_week,
    'activity_meetings_today'     => :activity_meetings_today,
    'activity_calls_due'          => :activity_calls_due,
    'activity_reminders_upcoming' => :activity_reminders_upcoming,
    'leads_mine'                  => :leads_mine,
    'leads_new_24h'               => :leads_new_24h,
    'leads_stale_48h'             => :leads_stale_48h,
    'deals_mine'                  => :deals_mine,
    'deals_closing_month'         => :deals_closing_month,
    'deals_closing_week'          => :deals_closing_week,
    'deals_stale_30d'             => :deals_stale_30d,
    'tickets_mine'                => :tickets_mine,
    'tickets_awaiting_parts'      => :tickets_awaiting_parts,
    'tickets_ready_for_invoice'   => :tickets_ready_for_invoice,
    'quotes_awaiting_response'    => :quotes_awaiting_response,
    'invoices_overdue'            => :invoices_overdue,
  }.freeze

  GROUPS = [
    { id: 'engagement', label: 'Hot Engagement',
      queue_ids: %w[engagement_opened_today engagement_clicked_today engagement_hot_reopeners engagement_opened_week] },
    { id: 'my_activity', label: 'My Open Activity',
      queue_ids: %w[activity_tasks_today activity_tasks_week activity_meetings_today activity_calls_due activity_reminders_upcoming] },
    { id: 'my_leads', label: 'My Leads',
      queue_ids: %w[leads_mine leads_new_24h leads_stale_48h] },
    { id: 'my_deals', label: 'My Deals',
      queue_ids: %w[deals_mine deals_closing_month deals_closing_week deals_stale_30d] },
    { id: 'my_service', label: 'My Service Work',
      queue_ids: %w[tickets_mine tickets_awaiting_parts tickets_ready_for_invoice] },
    { id: 'my_finance', label: 'My Finance',
      queue_ids: %w[quotes_awaiting_response invoices_overdue] },
  ].freeze

  # Default user preferences. Any key a user hasn't overridden falls back to these.
  DEFAULT_PREFERENCES = {
    new_leads_days:         1,
    stale_leads_days:       2,
    stale_deals_days:       30,
    reminders_window_days:  1,
    closing_week_days:      7,
    tasks_week_days:        7,
    hidden_queues:          [],
  }.freeze

  def initialize(company:, user:, queue_id: nil, filters: {}, page: 1, per_page: 50)
    @company  = company
    @user     = user
    @queue_id = queue_id
    @filters  = filters
    @page     = [[page.to_i, 1].max, 10_000].min
    @per_page = [[per_page.to_i, 1].max, 200].min
  end

  def summary
    cache_key = summary_cache_key
    Rails.cache.fetch(cache_key, expires_in: 60.seconds) do
      GROUPS.map do |group|
        queues = group[:queue_ids].reject { |qid| hidden_queue?(qid) }.map do |qid|
          scope = build_scope(qid)
          {
            id:    qid,
            label: queue_label(qid),
            count: scope ? scope.count : 0,
          }
        end
        { id: group[:id], label: group[:label], queues: queues }
      end
    end
  end

  def count
    scope = build_scope(@queue_id)
    scope ? scope.count : 0
  end

  def items
    scope = build_scope(@queue_id)
    return { items: [], meta: { total: 0, page: @page, per_page: @per_page, total_pages: 0 } } unless scope

    scope = apply_search(scope)
    scope = apply_sort(scope)
    total = scope.count
    total_pages = (total.to_f / @per_page).ceil
    records = scope.offset((@page - 1) * @per_page).limit(@per_page).to_a

    preload_lead_engagement(records.select { |r| r.is_a?(Lead) })

    {
      items: records.map { |r| normalize(r) },
      meta: { total: total, page: @page, per_page: @per_page, total_pages: total_pages },
    }
  end

  private

  # ─── User preferences ────────────────────────────────────────────

  def prefs
    @prefs ||= begin
      stored = if @user.respond_to?(:workqueue_preferences) && @user.workqueue_preferences.is_a?(Hash)
                 @user.workqueue_preferences.symbolize_keys
               else
                 {}
               end
      DEFAULT_PREFERENCES.merge(stored)
    end
  end

  def hidden_queue?(queue_id)
    hidden = Array(prefs[:hidden_queues]).map(&:to_s)
    hidden.include?(queue_id.to_s)
  end

  def summary_cache_key
    prefs_digest = Digest::MD5.hexdigest(prefs.sort.to_s)
    "workqueue_summary:#{@company.id}:#{@user.id}:#{Current.location_id}:#{prefs_digest}"
  end

  # Dynamic labels that reflect the current threshold values.
  def queue_label(queue_id)
    case queue_id
    when 'engagement_opened_today'     then 'Opened Email Today'
    when 'engagement_opened_week'      then 'Opened Email This Week'
    when 'engagement_clicked_today'    then 'Clicked Link Today'
    when 'engagement_hot_reopeners'    then 'Hot Reopeners (3+)'
    when 'activity_tasks_today'        then 'Tasks — Today & Overdue'
    when 'activity_tasks_week'         then "Tasks — Next #{prefs[:tasks_week_days]}d"
    when 'activity_meetings_today'     then 'Meetings — Today'
    when 'activity_calls_due'          then 'Calls — Due'
    when 'activity_reminders_upcoming' then "Reminders — Next #{prefs[:reminders_window_days]}d"
    when 'leads_mine'                  then 'My Leads'
    when 'leads_new_24h'               then "New — Last #{prefs[:new_leads_days]}d"
    when 'leads_stale_48h'             then "Untouched #{prefs[:stale_leads_days]}d+"
    when 'deals_mine'                  then 'My Open Deals'
    when 'deals_closing_month'         then 'Closing This Month'
    when 'deals_closing_week'          then "Closing Next #{prefs[:closing_week_days]}d"
    when 'deals_stale_30d'             then "Stale — #{prefs[:stale_deals_days]}+ Days"
    when 'tickets_mine'                then 'Assigned Tickets'
    when 'tickets_awaiting_parts'      then 'Awaiting Parts'
    when 'tickets_ready_for_invoice'   then 'Ready for Invoice'
    when 'quotes_awaiting_response'    then 'Quotes Awaiting Response'
    when 'invoices_overdue'            then 'Invoices Overdue'
    else queue_id.to_s.titleize
    end
  end

  # ─── Scope builder ───────────────────────────────────────────────

  def build_scope(queue_id)
    method_name = QUEUES[queue_id]
    return nil unless method_name

    scope = send(method_name)
    return nil unless scope

    apply_location_filter(scope)
  rescue => e
    Rails.logger.warn "[WorkqueueService] build_scope(#{queue_id}) failed: #{e.message}"
    nil
  end

  def apply_location_filter(scope)
    return scope unless Current.location_filtered?

    if scope.klass.column_names.include?('location_id')
      scope.where(location_id: Current.location_id)
    else
      scope
    end
  end

  # ─── Activity queues ─────────────────────────────────────────────

  def activity_tasks_today
    Task.where(company_id: @company.id, assigned_to_id: @user.id)
        .where.not(status: [:completed, :cancelled])
        .where('due_date IS NULL OR due_date <= ?', Date.current.end_of_day)
  end

  def activity_tasks_week
    window_end = prefs[:tasks_week_days].to_i.days.from_now.end_of_day
    Task.where(company_id: @company.id, assigned_to_id: @user.id)
        .where.not(status: [:completed, :cancelled])
        .where('due_date > ? AND due_date <= ?', Date.current.end_of_day, window_end)
  end

  def activity_meetings_today
    WorkqueueActivity.where(company_id: @company.id, assigned_to_id: @user.id, activity_type: 'meeting')
                     .where.not(status: %w[completed cancelled])
                     .where('due_date >= ? AND due_date <= ?', Date.current.beginning_of_day, Date.current.end_of_day)
                     .where(valid_parent_condition)
  end

  def activity_calls_due
    WorkqueueActivity.where(company_id: @company.id, assigned_to_id: @user.id, activity_type: 'call')
                     .where.not(status: %w[completed cancelled])
                     .where('due_date <= ?', Date.current.end_of_day)
                     .where(valid_parent_condition)
  end

  def activity_reminders_upcoming
    window_end = prefs[:reminders_window_days].to_i.days.from_now
    WorkqueueActivity.where(company_id: @company.id, assigned_to_id: @user.id)
                     .where.not(status: %w[completed cancelled])
                     .where('reminder_time IS NOT NULL AND reminder_time >= ? AND reminder_time <= ?',
                            Time.current, window_end)
                     .where(valid_parent_condition)
  end

  # Exclude activities whose parent Lead/Contact/Deal no longer exists or is effectively deleted.
  # We use a raw SQL condition that checks:
  #   - Lead parents: lead must exist, not converted, not lost/unqualified
  #   - Non-Lead parents: parent must exist (basic check)
  def valid_parent_condition
    <<~SQL.squish
      (
        (parent_type != 'Lead') OR
        (parent_type = 'Lead' AND EXISTS (
          SELECT 1 FROM leads
          WHERE leads.id = workqueue_activities.parent_id
            AND (leads.is_converted IS NULL OR leads.is_converted = false)
            AND leads.status NOT IN ('converted', 'lost', 'unqualified', 'dead')
        ))
      )
    SQL
  end

  # ─── Lead queues ─────────────────────────────────────────────────

  def leads_mine
    @company.leads.where(owner_id: @user.id)
                  .where.not(status: %w[converted lost unqualified])
  end

  def leads_new_24h
    cutoff = prefs[:new_leads_days].to_i.days.ago
    @company.leads.where(owner_id: @user.id)
                  .where('leads.created_at >= ?', cutoff)
  end

  def leads_stale_48h
    cutoff = prefs[:stale_leads_days].to_i.days.ago
    @company.leads.where(owner_id: @user.id)
                  .where.not(status: %w[converted lost unqualified])
                  .where('(leads.last_activity_at IS NULL AND leads.created_at < :t) OR leads.last_activity_at < :t',
                         t: cutoff)
  end

  # ─── Engagement queues ───────────────────────────────────────────

  def engagement_opened_today
    recency = engagement_lead_recency(event: 'opened', since: 24.hours.ago)
    engagement_scope_for(recency)
  end

  def engagement_opened_week
    recent  = engagement_lead_recency(event: 'opened', since: 24.hours.ago)
    weekly  = engagement_lead_recency(event: 'opened', since: 7.days.ago, before: 24.hours.ago)
    weekly.reject! { |lead_id, _| recent.key?(lead_id) }
    engagement_scope_for(weekly)
  end

  def engagement_clicked_today
    recency = engagement_lead_recency(event: 'clicked', since: 24.hours.ago)
    engagement_scope_for(recency)
  end

  def engagement_hot_reopeners
    cutoff = 48.hours.ago
    pairs = CampaignSend
              .joins(:campaign_enrollment)
              .where(company_id: @company.id)
              .where(campaign_enrollments: { recipient_type: 'Lead' })
              .where('campaign_sends.open_count >= ?', 3)
              .where('campaign_sends.opened_at >= ?', cutoff)
              .pluck('campaign_enrollments.recipient_id, campaign_sends.opened_at')

    recency = pairs.group_by(&:first).transform_values { |arr| arr.map(&:last).compact.max }
    engagement_scope_for(recency)
  end

  # Returns { lead_id => most_recent_event_timestamp } across both
  # CampaignSends (opened_at/clicked_at) and CommunicationEvents.
  def engagement_lead_recency(event:, since:, before: nil)
    campaign_field = event == 'opened' ? :opened_at : :clicked_at

    campaign_q = CampaignSend
                   .joins(:campaign_enrollment)
                   .where(company_id: @company.id)
                   .where(campaign_enrollments: { recipient_type: 'Lead' })
                   .where("campaign_sends.#{campaign_field} >= ?", since)
    campaign_q = campaign_q.where("campaign_sends.#{campaign_field} < ?", before) if before
    campaign_pairs = campaign_q.pluck("campaign_enrollments.recipient_id, campaign_sends.#{campaign_field}")

    comm_q = CommunicationEvent
               .joins(:communication)
               .where(event_type: event)
               .where(communications: { communicable_type: 'Lead', company_id: @company.id })
               .where('communication_events.occurred_at >= ?', since)
    comm_q = comm_q.where('communication_events.occurred_at < ?', before) if before
    comm_pairs = comm_q.pluck('communications.communicable_id, communication_events.occurred_at')

    (campaign_pairs + comm_pairs)
      .group_by(&:first)
      .transform_values { |arr| arr.map(&:last).compact.max }
  end

  def engagement_scope_for(recency_by_lead)
    return @company.leads.none if recency_by_lead.empty?

    ordered_ids = recency_by_lead.sort_by { |_, ts| -(ts ? ts.to_f : 0) }.map { |id, _| id.to_i }
    ids_csv = ordered_ids.join(',')

    @company.leads.where(owner_id: @user.id, id: ordered_ids)
                  .where.not(status: %w[converted lost unqualified])
                  .order(Arel.sql("array_position(ARRAY[#{ids_csv}]::bigint[], leads.id)"))
  end

  # ─── Deal queues ─────────────────────────────────────────────────

  def deals_mine
    @company.deals.where(deleted_at: nil, user_id: @user.id)
                  .where.not(stage: %w[closed_won closed_lost])
  end

  def deals_closing_month
    @company.deals.where(deleted_at: nil, user_id: @user.id)
                  .where.not(stage: %w[closed_won closed_lost])
                  .where(expected_close_date: Date.current.beginning_of_month..Date.current.end_of_month)
  end

  def deals_closing_week
    window_end = prefs[:closing_week_days].to_i.days.from_now.to_date
    @company.deals.where(deleted_at: nil, user_id: @user.id)
                  .where.not(stage: %w[closed_won closed_lost])
                  .where(expected_close_date: Date.current..window_end)
  end

  def deals_stale_30d
    cutoff = prefs[:stale_deals_days].to_i.days.ago
    @company.deals.where(deleted_at: nil, user_id: @user.id)
                  .where.not(stage: %w[closed_won closed_lost])
                  .where('deals.last_activity_at < :t OR (deals.last_activity_at IS NULL AND deals.created_at < :t)',
                         t: cutoff)
  end

  # ─── Service ticket queues ───────────────────────────────────────

  def tickets_mine
    @company.service_tickets.where(assigned_to: @user.id)
                            .where.not(status: %w[completed cancelled])
  end

  def tickets_awaiting_parts
    @company.service_tickets.where(assigned_to: @user.id, status: 'waiting_parts')
  end

  def tickets_ready_for_invoice
    @company.service_tickets.where(assigned_to: @user.id, status: 'completed')
  end

  # ─── Quote queues ────────────────────────────────────────────────

  def quotes_awaiting_response
    @company.quotes.where(is_deleted: [false, nil], sales_rep_id: @user.id, status: 'sent')
  end

  # ─── Invoice queues ──────────────────────────────────────────────

  def invoices_overdue
    @company.invoices.where(is_deleted: [false, nil], sales_rep_id: @user.id, status: 'sent')
                     .where('due_date < ?', Date.current)
  end

  # ─── Search ──────────────────────────────────────────────────────

  def apply_search(scope)
    term = @filters[:search].to_s.strip
    return scope if term.blank?

    pattern = "%#{sanitize_like(term)}%"

    case scope.klass.name
    when 'Task'
      scope.where('title ILIKE :p OR description ILIKE :p', p: pattern)
    when 'Lead'
      scope.where('first_name ILIKE :p OR last_name ILIKE :p OR email ILIKE :p OR phone ILIKE :p', p: pattern)
    when 'Deal'
      scope.where('name ILIKE :p OR deal_number ILIKE :p OR customer_name ILIKE :p', p: pattern)
    when 'ServiceTicket'
      scope.where('title ILIKE :p OR ticket_number ILIKE :p', p: pattern)
    when 'Quote'
      scope.where('quote_number ILIKE :p', p: pattern)
    when 'Invoice'
      scope.where('invoice_number ILIKE :p', p: pattern)
    when 'WorkqueueActivity'
      scope.where('subject ILIKE :p', p: pattern)
    else
      scope
    end
  end

  def sanitize_like(term)
    term.gsub(/[%_\\]/) { |m| "\\#{m}" }
  end

  # ─── Sort ────────────────────────────────────────────────────────

  def apply_sort(scope)
    case scope.klass.name
    when 'Task', 'WorkqueueActivity'
      scope.order(Arel.sql('due_date ASC NULLS LAST'))
    when 'Lead'
      scope.order(created_at: :desc)
    when 'Deal'
      scope.order(Arel.sql('expected_close_date ASC NULLS LAST'))
    when 'ServiceTicket'
      scope.order(created_at: :desc)
    when 'Quote', 'Invoice'
      scope.order(Arel.sql('due_date ASC NULLS LAST'))
    else
      scope
    end
  end

  # ─── Normalize ───────────────────────────────────────────────────

  def normalize(record)
    case record
    when Task          then normalize_task(record)
    when Lead          then normalize_lead(record)
    when Deal          then normalize_deal(record)
    when ServiceTicket then normalize_ticket(record)
    when Quote         then normalize_quote(record)
    when Invoice       then normalize_invoice(record)
    when WorkqueueActivity then normalize_activity(record)
    else
      { uid: "unknown-#{record.id}", entity_type: 'unknown', entity_id: record.id,
        title: record.try(:title) || record.try(:subject) || 'Unknown',
        subtitle: nil, status: nil, priority: nil, badge: nil, amount: nil,
        due_at: nil, last_activity_at: nil, link: '#' }
    end
  end

  def normalize_task(r)
    {
      uid:              "task-#{r.id}",
      entity_type:      'task',
      entity_id:        r.id,
      title:            r.title,
      subtitle:         r.description.to_s.truncate(120),
      status:           r.status,
      priority:         r.priority,
      badge:            r.task_module,
      amount:           nil,
      due_at:           r.due_date,
      last_activity_at: r.updated_at,
      link:             "/tasks/#{r.id}",
    }
  end

  def normalize_lead(r)
    eng = lead_engagement_for(r.id)
    {
      uid:                "lead-#{r.id}",
      entity_type:        'lead',
      entity_id:          r.id,
      title:              [r.first_name, r.last_name].compact.join(' ').presence || 'Unnamed Lead',
      subtitle:           r.email,
      status:             r.status,
      priority:           nil,
      badge:              r.try(:source)&.try(:name),
      amount:             nil,
      due_at:             nil,
      last_activity_at:   r.try(:last_activity_at),
      link:               "/crm/leads/#{r.id}",
      engagement_opens:   eng[:opens],
      engagement_clicks:  eng[:clicks],
      last_engagement_at: eng[:last_at],
      engagement_source:  eng[:source],
    }
  end

  EMPTY_ENGAGEMENT = { opens: 0, clicks: 0, last_at: nil, source: nil }.freeze

  def lead_engagement_for(lead_id)
    (@lead_engagement ||= {})[lead_id] || EMPTY_ENGAGEMENT
  end

  def preload_lead_engagement(leads)
    @lead_engagement ||= {}
    return if leads.empty?

    cutoff   = 7.days.ago
    lead_ids = leads.map(&:id)

    campaign_rows = CampaignSend
                      .joins(:campaign_enrollment, :campaign)
                      .where(company_id: @company.id)
                      .where(campaign_enrollments: { recipient_type: 'Lead', recipient_id: lead_ids })
                      .where('campaign_sends.opened_at >= :c OR campaign_sends.clicked_at >= :c', c: cutoff)
                      .pluck(
                        'campaign_enrollments.recipient_id',
                        'campaigns.name',
                        'campaign_sends.open_count',
                        'campaign_sends.click_count',
                        'campaign_sends.opened_at',
                        'campaign_sends.clicked_at'
                      )

    comm_rows = CommunicationEvent
                  .joins(:communication)
                  .where(event_type: %w[opened clicked])
                  .where(communications: { communicable_type: 'Lead', communicable_id: lead_ids, company_id: @company.id })
                  .where('communication_events.occurred_at >= ?', cutoff)
                  .pluck(
                    'communications.communicable_id',
                    'communication_events.event_type',
                    'communication_events.occurred_at'
                  )

    campaign_by_lead = campaign_rows.group_by(&:first)
    comm_by_lead     = comm_rows.group_by(&:first)

    lead_ids.each do |id|
      cs = campaign_by_lead[id] || []
      es = comm_by_lead[id]     || []

      opens      = 0
      clicks     = 0
      timestamps = []

      cs.each do |_, _name, oc, cc, oat, cat|
        if oat && oat >= cutoff
          opens += oc.to_i
          timestamps << oat
        end
        if cat && cat >= cutoff
          clicks += cc.to_i
          timestamps << cat
        end
      end

      es.each do |_, type, ts|
        type == 'opened' ? opens += 1 : clicks += 1
        timestamps << ts
      end

      source = if cs.any?
                 cs.first[1]
               elsif es.any?
                 'direct'
               end

      @lead_engagement[id] = {
        opens:   opens,
        clicks:  clicks,
        last_at: timestamps.compact.max,
        source:  source,
      }
    end
  end

  def normalize_deal(r)
    {
      uid:              "deal-#{r.id}",
      entity_type:      'deal',
      entity_id:        r.id,
      title:            r.try(:name) || r.try(:deal_number) || "Deal ##{r.id}",
      subtitle:         r.try(:customer_name),
      status:           r.stage,
      priority:         nil,
      badge:            r.stage,
      amount:           r.try(:value) || r.try(:selling_price),
      due_at:           r.expected_close_date&.to_time,
      last_activity_at: r.try(:last_activity_at),
      link:             "/deals/#{r.id}",
    }
  end

  def normalize_ticket(r)
    {
      uid:              "ticket-#{r.id}",
      entity_type:      'ticket',
      entity_id:        r.id,
      title:            r.title,
      subtitle:         r.try(:ticket_number),
      status:           r.status,
      priority:         r.priority,
      badge:            r.status,
      amount:           nil,
      due_at:           nil,
      last_activity_at: r.updated_at,
      link:             "/service/#{r.id}",
    }
  end

  def normalize_quote(r)
    {
      uid:              "quote-#{r.id}",
      entity_type:      'quote',
      entity_id:        r.id,
      title:            r.try(:quote_number) || "Quote ##{r.id}",
      subtitle:         nil,
      status:           r.status,
      priority:         nil,
      badge:            r.status,
      amount:           r.try(:total),
      due_at:           r.try(:due_date),
      last_activity_at: r.updated_at,
      link:             "/finance/quotes/#{r.id}",
    }
  end

  def normalize_invoice(r)
    {
      uid:              "invoice-#{r.id}",
      entity_type:      'invoice',
      entity_id:        r.id,
      title:            r.invoice_number,
      subtitle:         nil,
      status:           r.status,
      priority:         nil,
      badge:            r.status,
      amount:           r.try(:total),
      due_at:           r.try(:due_date)&.to_time,
      last_activity_at: r.updated_at,
      link:             "/finance/invoices/#{r.id}",
    }
  end

  def normalize_activity(r)
    parent_link = case r.parent_type
                  when 'Lead'    then "/crm/leads/#{r.parent_id}"
                  when 'Deal'    then "/deals/#{r.parent_id}"
                  when 'Contact' then "/contacts/#{r.parent_id}"
                  when 'Account' then "/accounts/#{r.parent_id}"
                  else '#'
                  end

    {
      uid:              r.uid,
      entity_type:      'activity',
      entity_id:        r.source_id,
      title:            r.subject.presence || "#{r.activity_type&.titleize} Activity",
      subtitle:         "#{r.parent_type} ##{r.parent_id}",
      status:           r.status,
      priority:         r.priority,
      badge:            r.activity_type,
      amount:           nil,
      due_at:           r.due_date,
      last_activity_at: r.updated_at,
      link:             parent_link,
    }
  end
end
