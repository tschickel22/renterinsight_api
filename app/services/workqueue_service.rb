# frozen_string_literal: true

require 'digest'

class WorkqueueService
  # Queues whose data doesn't fit the standard AR-scope pipeline (counts, search,
  # sort, paginate, normalize). These have their own count/items implementation.
  HASH_QUEUES = %w[inventory_hot_interest].freeze

  QUEUES = {
    'inventory_hot_interest'      => :prospect_hot_signals,
    'engagement_opened_today'          => :engagement_opened_today,
    'engagement_opened_week'           => :engagement_opened_week,
    'engagement_clicked_today'         => :engagement_clicked_today,
    'engagement_hot_reopeners'         => :engagement_hot_reopeners,
    'engagement_contact_opened_today'  => :engagement_contact_opened_today,
    'engagement_contact_opened_week'   => :engagement_contact_opened_week,
    'engagement_contact_clicked_today' => :engagement_contact_clicked_today,
    'activity_tasks_today'        => :activity_tasks_today,
    'activity_tasks_week'         => :activity_tasks_week,
    'activity_meetings_today'     => :activity_meetings_today,
    'activity_meetings_upcoming'  => :activity_meetings_upcoming,
    'activity_calls_due'          => :activity_calls_due,
    'activity_reminders_upcoming' => :activity_reminders_upcoming,
    'leads_replied'               => :leads_replied,
    'contacts_replied'            => :contacts_replied,
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
      queue_ids: %w[inventory_hot_interest engagement_opened_today engagement_clicked_today engagement_hot_reopeners engagement_opened_week engagement_contact_opened_today engagement_contact_clicked_today engagement_contact_opened_week] },
    { id: 'my_activity', label: 'My Open Activity',
      queue_ids: %w[activity_tasks_today activity_tasks_week activity_meetings_today activity_meetings_upcoming activity_calls_due activity_reminders_upcoming] },
    { id: 'my_leads', label: 'My Leads',
      queue_ids: %w[leads_replied contacts_replied leads_mine leads_new_24h leads_stale_48h] },
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
    meetings_window_days:   7,
    closing_week_days:      7,
    tasks_week_days:        7,
    replied_window_days:    7,
    show_empty_queues:      true,
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
          {
            id:    qid,
            label: queue_label(qid),
            count: count_for(qid),
          }
        end
        { id: group[:id], label: group[:label], queues: queues }
      end
    end
  end

  def count
    count_for(@queue_id)
  end

  def items
    if hash_queue?(@queue_id)
      return paginate_hash_queue(hash_queue_items(@queue_id))
    end

    scope = build_scope(@queue_id)
    return { items: [], meta: { total: 0, page: @page, per_page: @per_page, total_pages: 0 } } unless scope

    scope = apply_search(scope)
    scope = apply_sort(scope)
    total = scope.count
    total_pages = (total.to_f / @per_page).ceil
    records = scope.offset((@page - 1) * @per_page).limit(@per_page).to_a

    lead_records    = records.select { |r| r.is_a?(Lead) }
    contact_records = records.select { |r| r.is_a?(Contact) }
    preload_lead_engagement(lead_records)
    preload_lead_communications(lead_records)
    preload_contact_engagement(contact_records)
    preload_contact_communications(contact_records)
    preload_activity_parents(records.select { |r| r.is_a?(WorkqueueActivity) })
    preload_location_names(records)

    built = records.map { |r| [r, normalize(r).merge(location_fields_for(r))] }
    enrich_message_targets(built)

    {
      items: built.map(&:last),
      meta: { total: total, page: @page, per_page: @per_page, total_pages: total_pages },
    }
  end

  # Resolve the "messageable contact" for each row — the lead/contact a user
  # would actually email/text — and expose it as message_entity_type /
  # message_entity_id (+ entity_email/phone/name when not already set). Walks the
  # chain: deal/ticket -> their contact; task/activity -> their parent, and if
  # that parent is a deal/ticket, on to ITS contact. Batched (≤4 extra queries
  # per page) so the FE can (a) hide the email/text icon when there's nobody to
  # contact and (b) deep-link straight to that person's Communications tab.
  def enrich_message_targets(pairs)
    sources = pairs.map { |rec, item| message_source(rec, item) }

    deal_ids   = sources.select { |s| s && s[0] == 'Deal' }.map { |s| s[1] }.compact.uniq
    ticket_ids = sources.select { |s| s && s[0] == 'ServiceTicket' }.map { |s| s[1] }.compact.uniq
    deal_contact   = deal_ids.any?   ? Deal.where(id: deal_ids).pluck(:id, :contact_id).to_h : {}
    ticket_contact = ticket_ids.any? ? ServiceTicket.where(id: ticket_ids).pluck(:id, :contact_id).to_h : {}

    targets = sources.map do |src|
      next nil unless src
      case src[0]
      when 'Lead'          then ['lead', src[1]]
      when 'Contact'       then ['contact', src[1]]
      when 'Deal'          then (cid = deal_contact[src[1]])   ? ['contact', cid] : nil
      when 'ServiceTicket' then (cid = ticket_contact[src[1]]) ? ['contact', cid] : nil
      end
    end

    lead_ids    = targets.select { |t| t && t[0] == 'lead' }.map { |t| t[1] }.compact.uniq
    contact_ids = targets.select { |t| t && t[0] == 'contact' }.map { |t| t[1] }.compact.uniq
    leads    = lead_ids.any?    ? Lead.where(id: lead_ids).index_by(&:id) : {}
    contacts = contact_ids.any? ? Contact.where(id: contact_ids).index_by(&:id) : {}

    pairs.each_with_index do |(_rec, item), i|
      t = targets[i]
      next unless t
      rec = t[0] == 'lead' ? leads[t[1]] : contacts[t[1]]
      next unless rec
      item[:message_entity_type] = t[0]
      item[:message_entity_id]   = t[1]
      item[:entity_email] = rec.email       if item[:entity_email].blank?
      item[:entity_phone] = rec.try(:phone) if item[:entity_phone].blank?
      item[:entity_name] ||= [rec.first_name, rec.last_name].compact.reject(&:blank?).join(' ').presence
    end
  end

  # The record whose contact we message for a given item: self for lead/contact,
  # the deal/ticket for those rows, and the polymorphic parent for task/activity.
  def message_source(rec, item)
    case item[:entity_type]
    when 'lead'     then ['Lead', item[:entity_id]]
    when 'contact'  then ['Contact', item[:entity_id]]
    when 'deal'     then ['Deal', item[:entity_id]]
    when 'ticket'   then ['ServiceTicket', item[:entity_id]]
    when 'task'     then [rec.try(:taskable_type), rec.try(:taskable_id)]
    when 'activity' then [rec.try(:parent_type), rec.try(:parent_id)]
    end
  end

  # Batch-fetches location names for every location_id touched by the current
  # page so normalize doesn't do per-row lookups. WorkqueueActivity has no
  # location column of its own — its location is inherited from its parent
  # Lead/Deal/Contact/Account and resolved lazily in fetch_activity_location_id.
  def preload_location_names(records)
    location_ids = Set.new
    records.each do |r|
      lid = r.try(:location_id)
      location_ids << lid if lid.present?
    end
    @location_names = if location_ids.any?
                        Location.where(id: location_ids.to_a).pluck(:id, :name).to_h
                      else
                        {}
                      end
  end

  def location_fields_for(record)
    lid = record.try(:location_id)
    lid = fetch_activity_location_id(record) if lid.blank? && record.is_a?(WorkqueueActivity)
    return { location_id: nil, location_name: nil } if lid.blank?

    name = @location_names[lid] || Location.where(id: lid).pick(:name)
    @location_names[lid] ||= name
    { location_id: lid, location_name: name }
  end

  # For activity rows, the parent Lead/Deal/etc. carries the location.
  def fetch_activity_location_id(activity)
    parent_type = activity.parent_type
    parent_id   = activity.parent_id
    return nil if parent_type.blank? || parent_id.blank?

    klass = safe_parent_klass(parent_type)
    return nil unless klass

    @activity_parent_locations ||= {}
    key = [parent_type, parent_id]
    @activity_parent_locations[key] ||= klass.where(id: parent_id).pick(:location_id)
  end

  def safe_parent_klass(parent_type)
    case parent_type
    when 'Lead'    then Lead
    when 'Deal'    then Deal
    when 'Contact' then Contact
    when 'Account' then Account
    end
  end

  private

  def hash_queue?(queue_id)
    HASH_QUEUES.include?(queue_id.to_s)
  end

  def count_for(queue_id)
    if hash_queue?(queue_id)
      hash_queue_items(queue_id).size
    else
      scope = build_scope(queue_id)
      scope ? scope.count : 0
    end
  end

  def hash_queue_items(queue_id)
    @hash_queue_cache ||= {}
    @hash_queue_cache[queue_id] ||= begin
      method = QUEUES[queue_id]
      method ? Array(send(method)) : []
    rescue => e
      Rails.logger.warn "[WorkqueueService] hash_queue_items(#{queue_id}) failed: #{e.message}"
      []
    end
  end

  def paginate_hash_queue(items)
    term = @filters[:search].to_s.strip
    if term.present?
      pattern = term.downcase
      items = items.select { |it| it[:title].to_s.downcase.include?(pattern) || it[:subtitle].to_s.downcase.include?(pattern) }
    end

    total = items.size
    total_pages = (total.to_f / @per_page).ceil
    page_items = items[((@page - 1) * @per_page), @per_page] || []

    # Hash queues build their rows by hand, so they miss the AR pipeline's
    # message-target enrichment. Run it here too — without it the FE has no
    # email/phone to show and the row's quick actions can't deep-link into the
    # person's Communications tab. Rows are self-referential (lead/contact), so
    # message_source needs no backing record.
    enrich_message_targets(page_items.map { |it| [nil, it] })

    {
      items: page_items,
      meta: { total: total, page: @page, per_page: @per_page, total_pages: total_pages },
    }
  end

  public

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
    # No Current.location_id in the key — the Workqueue is a personal,
    # cross-location inbox, so its result set is the same regardless of the
    # location picker.
    "workqueue_summary:#{@company.id}:#{@user.id}:#{prefs_digest}"
  end

  # Dynamic labels that reflect the current threshold values.
  def queue_label(queue_id)
    case queue_id
    when 'inventory_hot_interest'      then 'Hot Inventory Interest'
    when 'engagement_opened_today'          then 'Leads — Opened Email Today'
    when 'engagement_opened_week'           then 'Leads — Opened Email This Week'
    when 'engagement_clicked_today'         then 'Leads — Clicked Link Today'
    when 'engagement_hot_reopeners'         then 'Leads — Hot Reopeners (3+)'
    when 'engagement_contact_opened_today'  then 'Contacts — Opened Email Today'
    when 'engagement_contact_opened_week'   then 'Contacts — Opened Email This Week'
    when 'engagement_contact_clicked_today' then 'Contacts — Clicked Link Today'
    when 'activity_tasks_today'        then 'Tasks — Today & Overdue'
    when 'activity_tasks_week'         then "Tasks — Next #{prefs[:tasks_week_days]}d"
    when 'activity_meetings_today'     then 'Meetings — Today'
    when 'activity_meetings_upcoming'  then "Meetings — Next #{prefs[:meetings_window_days]}d"
    when 'activity_calls_due'          then 'Calls — Due'
    when 'activity_reminders_upcoming' then "Reminders — Next #{prefs[:reminders_window_days]}d"
    when 'leads_replied'               then 'Replied — Needs Response'
    when 'contacts_replied'            then 'Contact Replies'
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

    # Deliberately NOT applying Current.location_id — Workqueue is a personal
    # cross-location inbox: whatever is assigned to me (mine) should surface
    # here regardless of which location I currently have selected. The
    # location picker still gates the rest of the app; Workqueue rows carry
    # their own location_id and the UI silently switches on click.
    scope
  rescue => e
    Rails.logger.warn "[WorkqueueService] build_scope(#{queue_id}) failed: #{e.message}"
    nil
  end

  # ─── Activity queues ─────────────────────────────────────────────

  # Task Center pulls tasks from FIVE sources (Task + 4 CRM activity
  # tables). Workqueue historically only queried the standalone Task
  # model, so lead/contact/deal/account activity tasks — which is where
  # most reps actually record follow-ups — never surfaced here. Switching
  # to the workqueue_activities view (already unions the 4 activity
  # tables) filtered to activity_type='task' matches what a rep sees in
  # Task Center. Standalone Task-model records are a followup — extending
  # the view to include them keeps this path simple.
  def activity_tasks_today
    WorkqueueActivity.where(company_id: @company.id, assigned_to_id: @user.id, activity_type: 'task')
                     .where.not(status: %w[completed cancelled])
                     .where('due_date IS NULL OR due_date <= ?', Date.current.end_of_day)
                     .where(valid_parent_condition)
  end

  def activity_tasks_week
    window_end = prefs[:tasks_week_days].to_i.days.from_now.end_of_day
    WorkqueueActivity.where(company_id: @company.id, assigned_to_id: @user.id, activity_type: 'task')
                     .where.not(status: %w[completed cancelled])
                     .where('due_date > ? AND due_date <= ?', Date.current.end_of_day, window_end)
                     .where(valid_parent_condition)
  end

  def activity_meetings_today
    # Meetings created from a Deal set start_time / end_time (calendar-style) and
    # leave due_date null. The old due_date-only filter silently hid them from
    # Today's Meetings. Prefer due_date when set, fall back to start_time.
    WorkqueueActivity.where(company_id: @company.id, assigned_to_id: @user.id, activity_type: 'meeting')
                     .where.not(status: %w[completed cancelled])
                     .where('COALESCE(due_date, start_time) >= ? AND COALESCE(due_date, start_time) <= ?',
                            Date.current.beginning_of_day, Date.current.end_of_day)
                     .where(valid_parent_condition)
  end

  # Forward-looking counterpart to activity_meetings_today — meetings scheduled
  # after today, within the user's meetings_window_days preference. Same
  # COALESCE(due_date, start_time) rule as the today queue so Deal-created
  # meetings (start_time only) are included.
  def activity_meetings_upcoming
    window_end = prefs[:meetings_window_days].to_i.days.from_now.end_of_day
    WorkqueueActivity.where(company_id: @company.id, assigned_to_id: @user.id, activity_type: 'meeting')
                     .where.not(status: %w[completed cancelled])
                     .where('COALESCE(due_date, start_time) > ? AND COALESCE(due_date, start_time) <= ?',
                            Date.current.end_of_day, window_end)
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
  #   - NULL parent_type (standalone Task rows): always pass — there's no
  #     parent to validate. Without the explicit NULL branch these get
  #     silently dropped because `NULL != 'Lead'` evaluates to NULL, which
  #     WHERE treats as false.
  #   - Lead parents: lead must exist, not converted, not lost/unqualified
  #   - Non-Lead parents: pass through (basic existence assumed)
  def valid_parent_condition
    <<~SQL.squish
      (
        parent_type IS NULL OR
        parent_type != 'Lead' OR
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

  # Leads owned by the user who have sent an inbound reply within the configured
  # window AND the user hasn't responded since. Implemented with a correlated
  # NOT EXISTS so the filter happens in one round-trip and stays an AR scope
  # (compatible with apply_search / apply_sort / pagination above).
  def leads_replied
    cutoff = prefs[:replied_window_days].to_i.days.ago
    @company.leads
            .where(owner_id: @user.id)
            .where.not(status: %w[converted lost unqualified])
            .where(<<~SQL.squish, cutoff: cutoff)
              EXISTS (
                SELECT 1 FROM communications c_in
                WHERE c_in.communicable_type = 'Lead'
                  AND c_in.communicable_id = leads.id
                  AND c_in.direction = 'inbound'
                  AND c_in.created_at >= :cutoff
                  AND NOT EXISTS (
                    SELECT 1 FROM communications c_out
                    WHERE c_out.communicable_type = 'Lead'
                      AND c_out.communicable_id = leads.id
                      AND c_out.direction = 'outbound'
                      AND c_out.created_at > c_in.created_at
                  )
              )
            SQL
  end

  # Contact equivalent of leads_replied. Contacts.owner_id mirrors leads.owner_id
  # in this schema, and the communicable_type differs ('Contact').
  def contacts_replied
    cutoff = prefs[:replied_window_days].to_i.days.ago
    @company.contacts
            .where(owner_id: @user.id)
            .where(is_deleted: [false, nil])
            .where(<<~SQL.squish, cutoff: cutoff)
              EXISTS (
                SELECT 1 FROM communications c_in
                WHERE c_in.communicable_type = 'Contact'
                  AND c_in.communicable_id = contacts.id
                  AND c_in.direction = 'inbound'
                  AND c_in.created_at >= :cutoff
                  AND NOT EXISTS (
                    SELECT 1 FROM communications c_out
                    WHERE c_out.communicable_type = 'Contact'
                      AND c_out.communicable_id = contacts.id
                      AND c_out.direction = 'outbound'
                      AND c_out.created_at > c_in.created_at
                  )
              )
            SQL
  end

  # ─── Inventory interest signals ──────────────────────────────────

  # Hot-inventory-interest signals: TrackedLinks scoped to a vehicle that the
  # entity (Lead/Contact) clicked recently. Used as a workqueue surface so reps
  # can act on prospects who showed they're shopping a specific home.
  #
  # Scoped to leads/contacts OWNED by the current user — Workqueue is a
  # personal inbox, so a rep should only see hot signals for prospects
  # they can actually act on. Prior behavior surfaced every rep's clicks
  # to every rep, creating noise + accidental disclosure across territories.
  def prospect_hot_signals
    hot_links = TrackedLink
                  .where(company_id: @company.id)
                  .where.not(vehicle_id: nil)
                  .where('click_count >= ?', 2)
                  .where('last_clicked_at >= ?', 48.hours.ago)
                  .order(click_count: :desc)
                  .limit(20)

    return [] if hot_links.empty?

    vehicle_ids = hot_links.map(&:vehicle_id).uniq
    vehicles_by_id = Vehicle.where(id: vehicle_ids).index_by(&:id)

    leads_by_id    = preload_owned_entities(hot_links, 'Lead',    Lead)
    contacts_by_id = preload_owned_entities(hot_links, 'Contact', Contact)

    hot_links.filter_map do |link|
      vehicle = vehicles_by_id[link.vehicle_id]
      next unless vehicle

      entity = case link.entity_type
               when 'Lead'    then leads_by_id[link.entity_id]
               when 'Contact' then contacts_by_id[link.entity_id]
               end
      next unless entity

      entity_name  = if entity.respond_to?(:first_name)
                       [entity.first_name, entity.last_name].compact.join(' ').presence
                     end
      entity_name ||= entity.try(:name) || 'Unknown'

      vehicle_name = [vehicle.year, vehicle.make, vehicle.model].compact.join(' ')
      time_ago_h   = ((Time.current - link.last_clicked_at) / 3600).round
      link_path    = link.entity_type == 'Lead' ? "/crm/leads/#{link.entity_id}" : "/contacts/#{link.entity_id}"

      # Location on hot-interest rows follows the vehicle the entity was
      # looking at — that's the physical store the lead/contact would visit
      # to see the home, so it's the right context to switch into.
      @location_names ||= {}
      loc_id   = vehicle.try(:location_id)
      loc_name = loc_id ? (@location_names[loc_id] ||= Location.where(id: loc_id).pick(:name)) : nil

      {
        uid:              "inventory_interest_#{link.entity_type}_#{link.entity_id}_#{link.vehicle_id}",
        entity_type:      link.entity_type.downcase,
        entity_id:        link.entity_id,
        title:            entity_name,
        subtitle:         "Viewed #{vehicle_name} #{link.click_count}x (#{time_ago_h}h ago)",
        status:           'hot_interest',
        priority:         link.click_count >= 4 ? 'high' : 'medium',
        badge:            "🔥 #{link.click_count} views",
        amount:           nil,
        link:             link_path,
        due_at:           nil,
        last_activity_at: link.last_clicked_at,
        location_id:      loc_id,
        location_name:    loc_name,
      }
    end
  end

  def preload_entities(links, type, klass)
    ids = links.select { |l| l.entity_type == type }.map(&:entity_id).compact.uniq
    return {} if ids.empty?
    klass.where(id: ids).index_by(&:id)
  end

  # Same as preload_entities but restricts to records owned by the
  # current user. Used by prospect_hot_signals to keep the queue scoped
  # to the rep's own book.
  def preload_owned_entities(links, type, klass)
    ids = links.select { |l| l.entity_type == type }.map(&:entity_id).compact.uniq
    return {} if ids.empty?
    klass.where(id: ids, owner_id: @user.id).index_by(&:id)
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

  # Contact-side engagement queues. Parallel to the Lead-side queues above but
  # sourced only from CommunicationEvent (direct sends from the Communication
  # Center) — campaign flows target Lead recipients today, so CampaignSend
  # would contribute nothing for Contacts.
  def engagement_contact_opened_today
    recency = engagement_contact_recency(event: 'opened', since: 24.hours.ago)
    engagement_contact_scope_for(recency)
  end

  def engagement_contact_opened_week
    recent = engagement_contact_recency(event: 'opened', since: 24.hours.ago)
    weekly = engagement_contact_recency(event: 'opened', since: 7.days.ago, before: 24.hours.ago)
    weekly.reject! { |contact_id, _| recent.key?(contact_id) }
    engagement_contact_scope_for(weekly)
  end

  def engagement_contact_clicked_today
    recency = engagement_contact_recency(event: 'clicked', since: 24.hours.ago)
    engagement_contact_scope_for(recency)
  end

  def engagement_contact_recency(event:, since:, before: nil)
    comm_q = CommunicationEvent
               .joins(:communication)
               .where(event_type: event)
               .where(communications: { communicable_type: 'Contact', company_id: @company.id })
               .where('communication_events.occurred_at >= ?', since)
    comm_q = comm_q.where('communication_events.occurred_at < ?', before) if before

    comm_q.pluck('communications.communicable_id, communication_events.occurred_at')
          .group_by(&:first)
          .transform_values { |arr| arr.map(&:last).compact.max }
  end

  def engagement_contact_scope_for(recency_by_contact)
    return @company.contacts.none if recency_by_contact.empty?

    ordered_ids = recency_by_contact.sort_by { |_, ts| -(ts ? ts.to_f : 0) }.map { |id, _| id.to_i }
    ids_csv = ordered_ids.join(',')

    @company.contacts.where(owner_id: @user.id, id: ordered_ids)
                     .where(is_deleted: [false, nil])
                     .order(Arel.sql("array_position(ARRAY[#{ids_csv}]::bigint[], contacts.id)"))
  end

  # ─── Deal queues ─────────────────────────────────────────────────

  def deals_mine
    @company.deals.where(deleted_at: nil, user_id: @user.id)
                  .where.not(stage: @company.closed_deal_stage_keys)
  end

  def deals_closing_month
    @company.deals.where(deleted_at: nil, user_id: @user.id)
                  .where.not(stage: @company.closed_deal_stage_keys)
                  .where(expected_close_date: Date.current.beginning_of_month..Date.current.end_of_month)
  end

  def deals_closing_week
    window_end = prefs[:closing_week_days].to_i.days.from_now.to_date
    @company.deals.where(deleted_at: nil, user_id: @user.id)
                  .where.not(stage: @company.closed_deal_stage_keys)
                  .where(expected_close_date: Date.current..window_end)
  end

  def deals_stale_30d
    cutoff = prefs[:stale_deals_days].to_i.days.ago
    @company.deals.where(deleted_at: nil, user_id: @user.id)
                  .where.not(stage: @company.closed_deal_stage_keys)
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
    # Delegates to Invoice.overdue so the queue matches the model's
    # canonical definition of overdue (due date passed, status NOT IN
    # paid/cancelled). Prior filter narrowed to status='sent' only and
    # missed 'viewed', 'partial', and any other in-flight states.
    @company.invoices
            .not_deleted
            .where(sales_rep_id: @user.id)
            .overdue
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
    when 'Contact'
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
      # Search subject and, when the row is a standalone task, its
      # description. description isn't a column on the view (activity
      # tables don't carry it consistently), so we fall through to the
      # underlying tasks table via a subquery. Keeps parity with Task
      # Center's search which hits both fields.
      scope.where(
        'subject ILIKE :p OR (source_table = :tasks AND EXISTS (' \
          'SELECT 1 FROM tasks t WHERE t.id = workqueue_activities.source_id ' \
            'AND t.description ILIKE :p))',
        p: pattern, tasks: 'tasks'
      )
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
    when 'Task'
      scope.order(Arel.sql('due_date ASC NULLS LAST'))
    when 'WorkqueueActivity'
      # Meetings created from a Deal carry only start_time; sort them by it
      # instead of dumping every NULL-due_date row at the end.
      scope.order(Arel.sql('COALESCE(due_date, start_time) ASC NULLS LAST'))
    when 'Lead'
      scope.order(created_at: :desc)
    when 'Contact'
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
    when Contact       then normalize_contact(record)
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
      link:             task_deep_link(r.taskable_type, r.taskable_id, r.id),
    }
  end

  # Deep-link a Task to the parent record it belongs to (Service Ticket, Deal,
  # etc.) instead of the generic Task Center detail. Service reminders live on
  # /service/{id}; a link to /tasks/{id} makes the user chase down the ticket
  # by hand, which is exactly what they flagged in the workqueue.
  # Falls back to /tasks/{id} for standalone tasks with no taskable.
  def task_deep_link(taskable_type, taskable_id, task_id)
    return "/tasks/#{task_id}" if taskable_type.blank? || taskable_id.blank?

    case taskable_type
    when 'ServiceTicket'  then "/service/#{taskable_id}"
    when 'Lead'           then "/crm/leads/#{taskable_id}"
    when 'Deal'           then "/deals/#{taskable_id}?tab=activities"
    when 'Contact'        then "/contacts/#{taskable_id}?tab=activities"
    when 'Account'        then "/accounts/#{taskable_id}?tab=activities"
    when 'Quote'          then "/quotes/#{taskable_id}"
    when 'Delivery'       then "/delivery/#{taskable_id}"
    when 'WarrantyClaim'  then "/warranty-mgmt/claims/#{taskable_id}"
    else                       "/tasks/#{task_id}"
    end
  end

  def normalize_lead(r)
    eng = lead_engagement_for(r.id)
    full_name = [r.first_name, r.last_name].compact.join(' ').presence
    outbound = (@last_outbounds ||= {})[r.id]
    inbound  = (@last_inbounds  ||= {})[r.id]
    has_unread_reply = inbound.present? && (outbound.nil? || inbound.created_at > outbound.created_at)

    {
      uid:                   "lead-#{r.id}",
      entity_type:           'lead',
      entity_id:             r.id,
      title:                 full_name || 'Unnamed Lead',
      subtitle:              r.email,
      status:                r.status,
      priority:              nil,
      badge:                 r.try(:source)&.try(:name),
      amount:                nil,
      due_at:                nil,
      last_activity_at:      r.try(:last_activity_at),
      link:                  "/crm/leads/#{r.id}",
      entity_phone:          r.try(:phone),
      entity_email:          r.email,
      entity_name:           full_name,
      engagement_opens:      eng[:opens],
      engagement_clicks:     eng[:clicks],
      last_engagement_at:    eng[:last_at],
      engagement_source:     eng[:source],
      last_outbound_at:      outbound&.created_at,
      last_outbound_channel: outbound&.channel,
      last_inbound_at:       inbound&.created_at,
      last_inbound_channel:  inbound&.channel,
      has_unread_reply:      has_unread_reply,
    }
  end

  EMPTY_ENGAGEMENT = { opens: 0, clicks: 0, last_at: nil, source: nil }.freeze

  def lead_engagement_for(lead_id)
    (@lead_engagement ||= {})[lead_id] || EMPTY_ENGAGEMENT
  end

  # Loads the most recent outbound and inbound Communication for each lead in a
  # single round-trip per direction using PostgreSQL's DISTINCT ON. Populates
  # @last_outbounds / @last_inbounds, keyed by lead id, so normalize_lead can
  # surface last_outbound_at / last_inbound_at / has_unread_reply without
  # per-row queries.
  def preload_lead_communications(leads)
    @last_outbounds = {}
    @last_inbounds  = {}
    return if leads.empty?

    lead_ids = leads.map(&:id)

    @last_outbounds = Communication
                        .where(communicable_type: 'Lead', communicable_id: lead_ids, direction: 'outbound')
                        .select('DISTINCT ON (communicable_id) communicable_id, created_at, channel')
                        .order('communicable_id, created_at DESC')
                        .index_by(&:communicable_id)

    @last_inbounds = Communication
                       .where(communicable_type: 'Lead', communicable_id: lead_ids, direction: 'inbound')
                       .select('DISTINCT ON (communicable_id) communicable_id, created_at, channel')
                       .order('communicable_id, created_at DESC')
                       .index_by(&:communicable_id)
  end

  # Same shape as preload_lead_communications but for the Contact pipeline.
  # Populates @contact_last_outbounds / @contact_last_inbounds, keyed by
  # contact id, so normalize_contact can surface reply context cheaply.
  def preload_contact_communications(contacts)
    @contact_last_outbounds = {}
    @contact_last_inbounds  = {}
    return if contacts.empty?

    contact_ids = contacts.map(&:id)

    @contact_last_outbounds = Communication
                                .where(communicable_type: 'Contact', communicable_id: contact_ids, direction: 'outbound')
                                .select('DISTINCT ON (communicable_id) communicable_id, created_at, channel')
                                .order('communicable_id, created_at DESC')
                                .index_by(&:communicable_id)

    @contact_last_inbounds = Communication
                               .where(communicable_type: 'Contact', communicable_id: contact_ids, direction: 'inbound')
                               .select('DISTINCT ON (communicable_id) communicable_id, created_at, channel')
                               .order('communicable_id, created_at DESC')
                               .index_by(&:communicable_id)
  end

  def normalize_contact(r)
    eng = contact_engagement_for(r.id)
    full_name = [r.first_name, r.last_name].compact.join(' ').presence
    outbound = (@contact_last_outbounds ||= {})[r.id]
    inbound  = (@contact_last_inbounds  ||= {})[r.id]
    has_unread_reply = inbound.present? && (outbound.nil? || inbound.created_at > outbound.created_at)

    {
      uid:                   "contact-#{r.id}",
      entity_type:           'contact',
      entity_id:             r.id,
      title:                 full_name || 'Unnamed Contact',
      subtitle:              r.email,
      status:                nil,
      priority:              nil,
      badge:                 nil,
      amount:                nil,
      due_at:                nil,
      last_activity_at:      r.try(:last_activity_at),
      link:                  "/contacts/#{r.id}",
      entity_phone:          r.try(:phone),
      entity_email:          r.email,
      entity_name:           full_name,
      engagement_opens:      eng[:opens],
      engagement_clicks:     eng[:clicks],
      last_engagement_at:    eng[:last_at],
      engagement_source:     eng[:source],
      last_outbound_at:      outbound&.created_at,
      last_outbound_channel: outbound&.channel,
      last_inbound_at:       inbound&.created_at,
      last_inbound_channel:  inbound&.channel,
      has_unread_reply:      has_unread_reply,
    }
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

      # Capitalized to match the contact-side value and the FE's own fallback —
      # the two sit in the same Source column on adjacent queues.
      source = if cs.any?
                 cs.first[1]
               elsif es.any?
                 'Direct'
               end

      @lead_engagement[id] = {
        opens:   opens,
        clicks:  clicks,
        last_at: timestamps.compact.max,
        source:  source,
      }
    end
  end

  # Contact-side counterpart to preload_lead_engagement, feeding the Opens /
  # Clicks / Last Engaged / Source columns on the engagement_contact_* queues.
  # Reads CommunicationEvent only: campaign flows enroll Lead recipients today,
  # so the CampaignSend half of the lead version would contribute nothing.
  def preload_contact_engagement(contacts)
    @contact_engagement ||= {}
    return if contacts.empty?

    cutoff      = 7.days.ago
    contact_ids = contacts.map(&:id)

    rows = CommunicationEvent
             .joins(:communication)
             .where(event_type: %w[opened clicked])
             .where(communications: { communicable_type: 'Contact', communicable_id: contact_ids, company_id: @company.id })
             .where('communication_events.occurred_at >= ?', cutoff)
             .pluck(
               'communications.communicable_id',
               'communication_events.event_type',
               'communication_events.occurred_at'
             )

    rows_by_contact = rows.group_by(&:first)

    contact_ids.each do |id|
      events     = rows_by_contact[id] || []
      opens      = 0
      clicks     = 0
      timestamps = []

      events.each do |_, type, ts|
        type == 'opened' ? opens += 1 : clicks += 1
        timestamps << ts
      end

      @contact_engagement[id] = {
        opens:   opens,
        clicks:  clicks,
        last_at: timestamps.compact.max,
        # Everything here came from a direct send out of the Communication
        # Center — there's no campaign name to attribute it to.
        source:  events.any? ? 'Direct' : nil,
      }
    end
  end

  def contact_engagement_for(contact_id)
    (@contact_engagement ||= {})[contact_id] || EMPTY_ENGAGEMENT
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
    # Task rows in the workqueue_activities view carry the polymorphic
    # taskable in parent_type/parent_id ('ServiceTicket', 'Deal', …), so a
    # service reminder should land the user on the ticket, not Task Center.
    # Only fall back to /tasks/{id} when there's genuinely no parent.
    is_task_row = r.source_table == 'tasks'
    parent_link = if is_task_row
                    task_deep_link(r.parent_type, r.parent_id, r.source_id)
                  else
                    case r.parent_type
                    when 'Lead'    then "/crm/leads/#{r.parent_id}"
                    when 'Deal'    then "/deals/#{r.parent_id}"
                    when 'Contact' then "/contacts/#{r.parent_id}"
                    when 'Account' then "/accounts/#{r.parent_id}"
                    else '#'
                    end
                  end

    parent_info = activity_parent_info(r.parent_type, r.parent_id)

    # Standalone tasks may have no parent; suppress the "Type ##" subtitle
    # so the row doesn't render " #" (empty type + hash).
    subtitle = if r.parent_type.present? && r.parent_id.present?
                 "#{r.parent_type} ##{r.parent_id}"
               else
                 nil
               end

    {
      uid:                r.uid,
      entity_type:        'activity',
      entity_id:          r.source_id,
      title:              r.subject.presence || "#{r.activity_type&.titleize} Activity",
      subtitle:           subtitle,
      status:             r.status,
      priority:           r.priority,
      badge:              r.activity_type,
      amount:             nil,
      # Meetings created from a Deal only set start_time — fall back so the FE
      # column doesn't render "—" for them.
      due_at:             r.due_date || r.start_time,
      last_activity_at:   r.updated_at,
      link:               parent_link,
      parent_entity_type: r.parent_type&.downcase,
      parent_entity_id:   r.parent_id,
      entity_name:        parent_info[:name],
      entity_phone:       parent_info[:phone],
      entity_email:       parent_info[:email],
    }
  end

  EMPTY_PARENT_INFO = { name: nil, phone: nil, email: nil }.freeze

  # Looks up cached parent info populated by preload_activity_parents. Falls
  # back to an empty hash so callers can always safely chain into [:name] etc.
  def activity_parent_info(parent_type, parent_id)
    return EMPTY_PARENT_INFO if parent_type.blank? || parent_id.blank?

    (@activity_parents || {}).dig(parent_type, parent_id) || EMPTY_PARENT_INFO
  end

  # Batches the parent-entity lookup for a page of WorkqueueActivity records so
  # normalize_activity doesn't hit the DB per item. One SELECT per parent type
  # actually present on the page; Deal returns name-only since deals carry no
  # phone/email of their own.
  def preload_activity_parents(activities)
    @activity_parents = {}
    return if activities.empty?

    grouped = activities.group_by(&:parent_type)

    grouped.each do |parent_type, rows|
      ids = rows.map(&:parent_id).compact.uniq
      next if ids.empty?

      @activity_parents[parent_type] =
        case parent_type
        when 'Lead'
          Lead.where(id: ids).pluck(:id, :first_name, :last_name, :phone, :email).each_with_object({}) do |(id, fn, ln, ph, em), h|
            h[id] = { name: [fn, ln].compact.reject(&:blank?).join(' ').presence, phone: ph, email: em }
          end
        when 'Contact'
          Contact.where(id: ids).pluck(:id, :first_name, :last_name, :phone, :email).each_with_object({}) do |(id, fn, ln, ph, em), h|
            h[id] = { name: [fn, ln].compact.reject(&:blank?).join(' ').presence, phone: ph, email: em }
          end
        when 'Account'
          Account.where(id: ids).pluck(:id, :name, :phone, :email).each_with_object({}) do |(id, name, ph, em), h|
            h[id] = { name: name, phone: ph, email: em }
          end
        when 'Deal'
          Deal.where(id: ids).pluck(:id, :name).each_with_object({}) do |(id, name), h|
            h[id] = { name: name, phone: nil, email: nil }
          end
        else
          {}
        end
    end
  end
end
