# frozen_string_literal: true

# CalendarService
#
# Aggregates calendar events from multiple sources (activities, service tickets, etc.)
# Handles RBAC filtering based on calendar view permissions
#
# Usage:
#   service = CalendarService.new(user, company, params)
#   events = service.aggregated_events
#
# View Types:
#   - 'my': User's own calendar (read/own permission)
#   - 'team': Team calendars based on assigned locations (read/assigned_locations permission)
#   - 'service_all': All service tickets (manage/all permission)
#   - 'service_unassigned': Unassigned service tickets (delete/all permission)
#   - 'all': All company calendars (read/all permission)
#
# Admins (platform_admin, super_admin, effective_admin) have full access to all views

class CalendarService
  # Activity-backed event types (CRM activities). service_ticket and standalone
  # tasks are separate sources handled in aggregated_events.
  ACTIVITY_EVENT_TYPES = %w[task meeting call reminder].freeze

  # Statuses treated as "done" for the hide_completed filter.
  COMPLETED_STATUSES = %w[completed cancelled done resolved closed].freeze

  attr_reader :user, :company, :params, :permission_service
  
  def initialize(user, company, params = {})
    @user = user
    @company = company
    @params = params
    @permission_service = PermissionService.new(user)
  end
  
  # Get aggregated calendar events
  #
  # @return [Array<Hash>] Array of unified event hashes
  def aggregated_events
    view = params[:view] || 'my'

    # Validate user has permission for requested view
    return [] unless can_view?(view)

    # Resolve the location scope once per request (memoized)
    location_scope
    
    events = []
    
    # Add activities if requested
    if requested_activity_types.nil? || requested_activity_types.any?
      events += load_activities(view)
    end
    
    # Add standalone tasks
    if include_type?('task')
      events += load_tasks(view)
    end
    
    # Add service tickets if requested
    if include_type?('service_ticket')
      events += load_service_tickets(view)
    end
    
    # Apply date range filter
    events = filter_by_date_range(events)

    # Hide completed/cancelled events if requested
    events = filter_out_completed(events) if boolean_param?(:hide_completed)

    # Hide events that have already ended if requested
    events = filter_out_past(events) if boolean_param?(:hide_past)

    # Apply status filter
    events = filter_by_status(events) if params[:status].present?
    
    # Apply priority filter
    events = filter_by_priority(events) if params[:priority].present?
    
    # Apply assigned_to filter
    events = filter_by_assigned_to(events) if params[:assigned_to].present?
    
    # Sort by start time
    events.sort_by { |e| e[:start] || Time.current }
  end
  
  private
  
  # Check if user can view the requested calendar
  def can_view?(view)
    # Platform admins can view all
    return true if user.platform_admin?
    return true if user.super_admin?
    
    # Company admins can view all
    return true if user.effective_admin?
    
    # If company doesn't use RBAC, allow all
    return true unless company&.use_rbac_system
    
    # Calendar permissions use standard actions with different scopes:
    # - 'read' with 'own' = view personal calendar
    # - 'read' with 'assigned_locations' = view team calendars
    # - 'read' with 'all' = view all company calendars
    # - 'manage' with 'all' = view all service tickets
    # - 'delete' with 'all' = view unassigned service tickets
    case view
    when 'my'
      permission_service.can?('calendar', 'read', 'own') ||
        permission_service.can?('calendar', 'read', 'all')
    when 'team'
      permission_service.can?('calendar', 'read', 'assigned_locations') ||
        permission_service.can?('calendar', 'read', 'all')
    when 'service_all'
      permission_service.can?('calendar', 'manage', 'all')
    when 'service_unassigned'
      permission_service.can?('calendar', 'delete', 'all')
    when 'all'
      permission_service.can?('calendar', 'read', 'all')
    else
      false
    end
  end
  
  # Check if event type should be included
  def include_type?(type)
    return true if params[:types].blank?
    Array(params[:types]).include?(type)
  end

  # Activity types the caller asked for. nil = no types filter (load all).
  # An empty array means the caller filtered to non-activity types only
  # (e.g. just service_ticket), so activity loading is skipped entirely.
  def requested_activity_types
    return nil if params[:types].blank?
    @requested_activity_types ||= Array(params[:types]).map(&:to_s) & ACTIVITY_EVENT_TYPES
  end

  def boolean_param?(key)
    ActiveModel::Type::Boolean.new.cast(params[key])
  end
  
  # Load activities from all modules (leads, accounts, contacts, deals)
  def load_activities(view)
    activities = []
    
    # Admins can see all activities
    is_admin = user.platform_admin? || user.super_admin? || user.effective_admin?
    
    # If user has calendar permission, they should see activities from all modules
    # Otherwise, check individual module permissions
    has_calendar_permission = is_admin ||
                             permission_service.can?('calendar', 'read', 'assigned_locations') ||
                             permission_service.can?('calendar', 'read', 'all')
    
    # Lead Activities
    if has_calendar_permission ||
       permission_service.can?('leads', 'read', 'assigned_locations') ||
       permission_service.can?('leads', 'read', 'all')
      activities += load_lead_activities(view)
    end
    
    # Account Activities
    if has_calendar_permission ||
       permission_service.can?('crm', 'read', 'assigned_locations') ||
       permission_service.can?('crm', 'read', 'all')
      activities += load_account_activities(view)
    end
    
    # Contact Activities
    if has_calendar_permission ||
       permission_service.can?('crm', 'read', 'assigned_locations') ||
       permission_service.can?('crm', 'read', 'all')
      activities += load_contact_activities(view)
    end
    
    # Deal Activities
    if has_calendar_permission ||
       permission_service.can?('deals', 'read', 'assigned_locations') ||
       permission_service.can?('deals', 'read', 'all')
      activities += load_deal_activities(view)
    end
    
    activities
  end
  
  # Load lead activities
  def load_lead_activities(view)
    activities = LeadActivity.joins(:lead).where(leads: {company_id: company.id})
    activities = activities.includes(:lead, :assigned_to)
    activities = filter_activities_by_view(activities, view)
    
    activities.map { |activity| activity_to_event(activity, 'lead') }.compact
  end
  
  # Load account activities
  def load_account_activities(view)
    activities = AccountActivity.joins(:account).where(accounts: {company_id: company.id})
    activities = activities.includes(:account, :assigned_to)
    activities = filter_activities_by_view(activities, view)
    
    activities.map { |activity| activity_to_event(activity, 'account') }.compact
  end
  
  # Load contact activities
  def load_contact_activities(view)
    activities = ContactActivity.joins(:contact).where(contacts: {company_id: company.id})
    activities = activities.includes(:contact, :assigned_to)
    activities = filter_activities_by_view(activities, view)
    
    activities.map { |activity| activity_to_event(activity, 'contact') }.compact
  end
  
  # Load deal activities
  def load_deal_activities(view)
    activities = DealActivity.joins(:deal).where(deals: {company_id: company.id})
    activities = activities.includes(:deal, :assigned_to)
    activities = filter_activities_by_view(activities, view)
    
    activities.map { |activity| activity_to_event(activity, 'deal') }.compact
  end
  
  # Load standalone tasks
  def load_tasks(view)
    # Admins can see all tasks
    is_admin = user.platform_admin? || user.super_admin? || user.effective_admin?
    
    # Calendar permission grants access to all tasks, or check specific tasks permission
    has_calendar_permission = is_admin ||
                             permission_service.can?('calendar', 'read', 'assigned_locations') ||
                             permission_service.can?('calendar', 'read', 'all')
    
    return [] unless has_calendar_permission ||
                     permission_service.can?('tasks', 'read', 'assigned_locations') ||
                     permission_service.can?('tasks', 'read', 'all')
    
    # Tasks don't have is_deleted column - only filter completed/cancelled if needed
    tasks = company.tasks.where.not(status: [:completed, :cancelled])
    scope = location_scope

    tasks = case view
    when 'my'
      tasks.where(assigned_to_id: user.id)
    when 'team'
      tasks = tasks.where(assigned_to_id: get_team_user_ids(scope))
      tasks = tasks.where(location_id: scope) if scope.present?
      tasks
    when 'all'
      scope.present? ? tasks.where(location_id: scope) : tasks
    else
      tasks.where(assigned_to_id: user.id)
    end

    tasks.map { |task| task_to_event(task) }.compact
  end
  
  # Filter activities by calendar view. Both `team` and `all` respect the
  # resolved location_scope so admins and location-tier users see counts that
  # obey the same location boundary; `my` is intentionally location-agnostic
  # (your own assignments regardless of where the parent record lives).
  def filter_activities_by_view(activities, view)
    # Honor the types[] filter at the query level — without this, requesting
    # "meeting" still returned every task/call/reminder activity.
    activities = activities.where(activity_type: requested_activity_types) if requested_activity_types.present?

    parent_table = get_parent_table_name(activities)
    scope = location_scope

    case view
    when 'my'
      activities.where(assigned_to_id: user.id)
    when 'team'
      activities = activities.where(assigned_to_id: get_team_user_ids(scope))
      activities = activities.where("#{parent_table}.location_id" => scope) if scope.present?
      activities
    when 'all'
      scope.present? ? activities.where("#{parent_table}.location_id" => scope) : activities
    else
      activities.where(assigned_to_id: user.id)
    end
  end
  
  # Get parent table name for location filtering
  def get_parent_table_name(activities)
    case activities.model_name.name
    when 'LeadActivity'
      'leads'
    when 'AccountActivity'
      'accounts'
    when 'ContactActivity'
      'contacts'
    when 'DealActivity'
      'deals'
    else
      'leads'  # Fallback
    end
  end
  
  # Load service tickets
  def load_service_tickets(view)
    # Admins can see all service tickets
    is_admin = user.platform_admin? || user.super_admin? || user.effective_admin?
    
    # Calendar permission grants access to service tickets, or check specific service/calendar permissions
    has_calendar_permission = is_admin ||
                             permission_service.can?('calendar', 'read', 'assigned_locations') ||
                             permission_service.can?('calendar', 'read', 'all') ||
                             permission_service.can?('calendar', 'manage', 'all') ||
                             permission_service.can?('calendar', 'delete', 'all')
    
    return [] unless has_calendar_permission ||
                     permission_service.can?('service', 'read', 'assigned_locations') ||
                     permission_service.can?('service', 'read', 'all')
    
    tickets = company.service_tickets  # Remove .includes(:assigned_to_user) - it's a method not association

    # Filter by scheduled date - only show tickets with scheduled dates
    tickets = tickets.where.not(scheduled_date: nil)
    scope = location_scope

    tickets = case view
    when 'my'
      tickets.where(assigned_to: user.id.to_s)
    when 'team'
      tickets = tickets.where(assigned_to: get_team_user_ids(scope).map(&:to_s))
      tickets = tickets.where(location_id: scope) if scope.present?
      tickets
    when 'service_all'
      scope.present? ? tickets.where(location_id: scope) : tickets
    when 'service_unassigned'
      base = tickets.where(assigned_to: [nil, ''])
      scope.present? ? base.where(location_id: scope) : base
    when 'all'
      scope.present? ? tickets.where(location_id: scope) : tickets
    else
      tickets.where(assigned_to: user.id.to_s)
    end

    tickets.map { |ticket| service_ticket_to_event(ticket) }.compact  # Remove nil values
  end
  
  # Get team user IDs. When a location scope is provided, "team" is the set of
  # active users assigned to those locations (via UserLocation) — the rule is
  # the same for admins and location-tier users. When scope is nil, team falls
  # back to every active user in the company (whole-company team).
  def get_team_user_ids(scope = nil)
    return [user.id] unless user.uses_rbac?

    base = company.users.where(status: 'active')

    if scope.present?
      user_ids_at_scope = UserLocation.where(location_id: scope).pluck(:user_id).uniq
      base.where(id: user_ids_at_scope).pluck(:id)
    else
      base.pluck(:id)
    end
  end

  # Resolve the location filter the calendar should apply. Priority:
  #   1. Explicit `location_ids[]` param (calendar's own filter UI)
  #   2. Header-driven `Current.location_id` (global location selector)
  #   3. Non-admin's `accessible_location_ids` (fall back to their assigned locs)
  #   4. nil (means "no location filter" — the caller sees the whole company)
  # Returns an Array<Integer> or nil. Never returns []; empty resolves to nil.
  def location_scope
    return @location_scope if defined?(@location_scope)

    explicit = Array(params[:location_ids]).map(&:to_i).reject(&:zero?)
    if explicit.any?
      # Guard against cross-tenant IDs sneaking through the query string.
      valid = company.locations.where(id: explicit).pluck(:id)
      @location_scope = valid.presence
    elsif Current.location_id.present?
      @location_scope = [Current.location_id.to_i]
    elsif !user.effective_admin? && permission_service.accessible_location_ids.any?
      @location_scope = permission_service.accessible_location_ids
    else
      @location_scope = nil
    end
  end
  
  # Convert activity to unified event format
  def activity_to_event(activity, source_type)
    # Determine entity info
    entity = activity.send(source_type)
    entity_name = case source_type
    when 'lead'
      entity&.full_name || 'Unknown Lead'
    when 'account'
      entity&.name || 'Unknown Account'
    when 'contact'
      entity&.full_name || 'Unknown Contact'
    when 'deal'
      entity&.name || 'Unknown Deal'
    end
    
    # Determine start/end times based on activity type
    start_time, end_time, all_day = calculate_activity_times(activity)
    
    # Return nil if no valid time could be calculated
    return nil if start_time.nil?
    
    # Color by activity type
    color = activity_color(activity.activity_type)
    
    {
      id: "#{source_type}-activity-#{activity.id}",
      title: activity.subject,
      type: activity.activity_type,
      start: start_time.iso8601,
      end: end_time.iso8601,
      all_day: all_day,
      status: activity.status,
      priority: activity.priority,
      description: activity.description,
      assigned_to: activity.assigned_to ? {
        id: activity.assigned_to.id,
        name: activity.assigned_to.full_name,
        email: activity.assigned_to.email
      } : nil,
      source: {
        type: source_type,
        id: entity&.id,
        name: entity_name
      },
      color: color,
      entity_name: entity_name,
      entity_type: source_type,
      entity_id: entity&.id
    }
  end
  
  # Convert task to unified event format
  def task_to_event(task)
    # Return nil if no due date
    return nil if task.due_date.blank?
    
    # Calculate start/end times
    start_time = task.due_date.is_a?(DateTime) ? task.due_date : task.due_date.to_time.change(hour: 9)
    # Tasks don't have estimated_hours column - use default 1 hour duration
    duration = task.respond_to?(:estimated_hours) ? (task.estimated_hours || 1) : 1
    end_time = start_time + duration.hours
    
    # Determine entity info if task is linked to something
    entity_name = if task.taskable.present?
      case task.taskable_type
      when 'Lead'
        task.taskable.full_name rescue 'Unknown Lead'
      when 'Account'
        task.taskable.name rescue 'Unknown Account'
      when 'Contact'
        task.taskable.full_name rescue 'Unknown Contact'
      when 'Deal'
        task.taskable.name rescue 'Unknown Deal'
      when 'ServiceTicket'
        task.taskable.title rescue 'Service Ticket'
      else
        task.taskable_type
      end
    else
      'Standalone Task'
    end
    
    {
      id: "task-#{task.id}",
      title: task.title,
      type: 'task',
      start: start_time.iso8601,
      end: end_time.iso8601,
      all_day: false,
      status: task.status,
      priority: task.priority,
      description: task.description,
      assigned_to: task.assigned_to ? {
        id: task.assigned_to.id,
        name: task.assigned_to.full_name,
        email: task.assigned_to.email
      } : nil,
      source: {
        type: 'task',
        id: task.id,
        name: task.title
      },
      color: '#3B82F6',  # Blue for tasks
      entity_name: entity_name,
      entity_type: task.taskable_type&.downcase || 'task',
      entity_id: task.taskable_id || task.id,
      task_module: task.task_module,
      overdue: task.overdue?
    }
  end
  
  # Calculate start/end times based on activity type
  def calculate_activity_times(activity)
    # Get duration from either 'estimated_hours' or 'duration' field
    duration_hours = if activity.respond_to?(:estimated_hours)
      activity.estimated_hours
    elsif activity.respond_to?(:duration)
      activity.duration
    else
      nil
    end
    duration_hours ||= 1  # Default to 1 hour if not set
    
    case activity.activity_type
    when 'task'
      # Tasks: Use due_date + duration
      if activity.due_date.present?
        # If due_date is already a datetime, use it as-is
        # Otherwise assume it's at 9:00 AM
        start_time = activity.due_date.is_a?(DateTime) ? activity.due_date : activity.due_date.to_time.change(hour: 9)
        end_time = start_time + duration_hours.hours
        [start_time, end_time, false]
      else
        [nil, nil, false]  # No date = don't show on calendar
      end
      
    when 'meeting'
      # Meetings: Use start_time; end_time when it's usable, else duration
      # (default 1 hour). Missing or corrupt end (reschedules can leave it
      # before the new start) must not drop the meeting or trip hide_past.
      if activity.start_time.present?
        end_time = if activity.end_time.present? && activity.end_time > activity.start_time
                     activity.end_time
                   else
                     activity.start_time + duration_hours.hours
                   end
        [activity.start_time, end_time, false]
      elsif activity.due_date.present?
        # Fallback: use due_date with 1-hour duration
        start_time = activity.due_date.is_a?(DateTime) ? activity.due_date : activity.due_date.to_time.change(hour: 9)
        [start_time, start_time + 1.hour, false]
      else
        [nil, nil, false]
      end
      
    when 'call'
      # Calls: Use due_date (scheduled time) with duration
      if activity.due_date.present?
        start_time = activity.due_date.is_a?(DateTime) ? activity.due_date : activity.due_date.to_time.change(hour: 9)
        end_time = start_time + duration_hours.hours
        [start_time, end_time, false]
      else
        [nil, nil, false]
      end
      
    when 'reminder'
      # Reminders: Use reminder_time with duration
      if activity.reminder_time.present?
        start_time = activity.reminder_time
        end_time = start_time + duration_hours.hours
        [start_time, end_time, false]
      elsif activity.due_date.present?
        # Fallback to due_date
        start_time = activity.due_date.is_a?(DateTime) ? activity.due_date : activity.due_date.to_time.change(hour: 9)
        [start_time, start_time + 1.hour, false]
      else
        [nil, nil, false]
      end
      
    else
      # Other activity types: Try start_time/end_time, fallback to due_date
      if activity.start_time.present?
        end_time = activity.end_time || activity.start_time + 1.hour
        [activity.start_time, end_time, false]
      elsif activity.due_date.present?
        start_time = activity.due_date.is_a?(DateTime) ? activity.due_date : activity.due_date.to_time.change(hour: 9)
        [start_time, start_time + 1.hour, false]
      else
        [nil, nil, false]
      end
    end
  end
  
  # Convert service ticket to unified event format
  def service_ticket_to_event(ticket)
    # Combine scheduled_date + scheduled_time to create start datetime
    if ticket.scheduled_date.present?
      scheduled_time = ticket.custom_fields&.dig('scheduledTime') || '09:00'
      estimated_hours = ticket.custom_fields&.dig('estimatedHours') || 1
      
      # Parse the date and time
      start_datetime = DateTime.parse("#{ticket.scheduled_date} #{scheduled_time}")
      end_datetime = start_datetime + estimated_hours.hours
      
      {
        id: "service-ticket-#{ticket.id}",
        title: ticket.title,
        type: 'service_ticket',
        start: start_datetime.iso8601,  # ISO datetime string
        end: end_datetime.iso8601,      # ISO datetime string
        all_day: false,                  # CRITICAL: no longer all-day!
        status: ticket.status,
        priority: ticket.priority,
        description: ticket.description,
        assigned_to: ticket.assigned_to_user ? {
          id: ticket.assigned_to_user.id,
          name: ticket.assigned_to_user.full_name,
          email: ticket.assigned_to_user.email
        } : nil,
        source: {
          type: 'service_ticket',
          id: ticket.id,
          name: ticket.title
        },
        color: '#EF4444',  # Red for service tickets
        entity_name: 'Service Ticket',
        entity_type: 'service_ticket',
        entity_id: ticket.id,
        location_id: ticket.location_id,
        vehicle_id: ticket.vehicle_id,
        account_id: ticket.account_id,
        contact_id: ticket.contact_id
      }
    else
      # No scheduled date - don't add to calendar or make it all-day
      nil
    end
  end
  
  # Get color for activity type
  def activity_color(activity_type)
    case activity_type
    when 'task'
      '#3B82F6'  # Blue
    when 'meeting'
      '#10B981'  # Green
    when 'call'
      '#F59E0B'  # Orange
    when 'reminder'
      '#8B5CF6'  # Purple
    else
      '#6B7280'  # Gray
    end
  end
  
  # Filter events by date range
  def filter_by_date_range(events)
    return events if params[:start_date].blank? && params[:end_date].blank?
    
    start_date = params[:start_date].present? ? Time.zone.parse(params[:start_date]) : nil
    end_date = params[:end_date].present? ? Time.zone.parse(params[:end_date]) : nil
    
    events.select do |event|
      event_start = event[:start]
      event_end = event[:end]
      
      next false if event_start.nil? && event_end.nil?
      
      in_range = true
      in_range = in_range && event_start >= start_date if start_date.present? && event_start.present?
      in_range = in_range && event_end <= end_date if end_date.present? && event_end.present?
      in_range
    end
  end
  
  # Drop events whose status marks them as finished (hide_completed param)
  def filter_out_completed(events)
    events.reject { |event| COMPLETED_STATUSES.include?(event[:status].to_s.downcase) }
  end

  # Drop events that have already ended (hide_past param). An in-progress
  # event (started but not yet ended) stays visible. Events with unparseable
  # or missing times are kept rather than silently hidden.
  def filter_out_past(events)
    now = Time.current
    events.select do |event|
      # Overdue-but-open items are still actionable work — hiding them buries
      # tasks the user hasn't done. "Past" only hides events that are over AND
      # finished/cancelled; hide_completed covers finished items anywhere in time.
      next true unless COMPLETED_STATUSES.include?(event[:status].to_s.downcase)

      # Use the LATEST of start/end — corrupt records can carry an end before
      # their start, and trusting end alone hides events that haven't happened
      times = [event[:end], event[:start]].filter_map do |ts|
        next if ts.blank?

        begin
          Time.zone.parse(ts.to_s)
        rescue ArgumentError, TypeError
          nil
        end
      end
      times.empty? || times.max >= now
    end
  end

  # Filter events by status
  def filter_by_status(events)
    statuses = Array(params[:status])
    events.select { |event| statuses.include?(event[:status]) }
  end
  
  # Filter events by priority
  def filter_by_priority(events)
    priorities = Array(params[:priority])
    events.select { |event| priorities.include?(event[:priority]) }
  end
  
  # Filter events by assigned user
  def filter_by_assigned_to(events)
    assigned_to_ids = Array(params[:assigned_to]).map(&:to_i)
    events.select { |event| assigned_to_ids.include?(event[:assigned_to]&.dig(:id)) }
  end
end
