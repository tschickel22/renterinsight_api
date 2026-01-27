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
    
    events = []
    
    # Add activities if requested
    if include_type?('task') || include_type?('meeting') || include_type?('call') || include_type?('reminder')
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
    
    tasks = case view
    when 'my'
      tasks.where(assigned_to_id: user.id)
    when 'team'
      team_user_ids = get_team_user_ids
      tasks.where(assigned_to_id: team_user_ids)
    when 'all'
      # Filter by location based on user context
      if Current.location_filtered?
        tasks.where(location_id: Current.location_id)
      elsif !user.effective_admin? && permission_service.accessible_location_ids.any?
        tasks.where(location_id: permission_service.accessible_location_ids)
      else
        tasks
      end
    else
      tasks.where(assigned_to_id: user.id)
    end
    
    tasks.map { |task| task_to_event(task) }.compact
  end
  
  # Filter activities by calendar view
  def filter_activities_by_view(activities, view)
    case view
    when 'my'
      activities.where(assigned_to_id: user.id)
    when 'team'
      # Get team members based on assigned locations
      team_user_ids = get_team_user_ids
      activities.where(assigned_to_id: team_user_ids)
    when 'all'
      parent_table = get_parent_table_name(activities)
      
      # Apply location filter based on user context
      if Current.location_filtered?
        # Location selector is active - filter to that specific location
        activities = activities.where("#{parent_table}.location_id" => Current.location_id)
      elsif !user.effective_admin? && permission_service.accessible_location_ids.any?
        # Location-tier user with no location selected - filter to ALL their assigned locations
        activities = activities.where("#{parent_table}.location_id" => permission_service.accessible_location_ids)
      end
      # else: Company admin with no filter = sees everything
      
      activities
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
    
    tickets = case view
    when 'my'
      tickets.where(assigned_to: user.id.to_s)
    when 'team'
      team_user_ids = get_team_user_ids
      tickets.where(assigned_to: team_user_ids.map(&:to_s))
    when 'service_all'
      # All service tickets - filter by location
      if Current.location_filtered?
        tickets.where(location_id: Current.location_id)
      elsif !user.effective_admin? && permission_service.accessible_location_ids.any?
        tickets.where(location_id: permission_service.accessible_location_ids)
      else
        tickets
      end
    when 'service_unassigned'
      # Unassigned tickets - filter by location
      base = tickets.where(assigned_to: [nil, ''])
      if Current.location_filtered?
        base.where(location_id: Current.location_id)
      elsif !user.effective_admin? && permission_service.accessible_location_ids.any?
        base.where(location_id: permission_service.accessible_location_ids)
      else
        base
      end
    when 'all'
      # All tickets - filter by location
      if Current.location_filtered?
        tickets.where(location_id: Current.location_id)
      elsif !user.effective_admin? && permission_service.accessible_location_ids.any?
        tickets.where(location_id: permission_service.accessible_location_ids)
      else
        tickets
      end
    else
      tickets.where(assigned_to: user.id.to_s)
    end
    
    tickets.map { |ticket| service_ticket_to_event(ticket) }.compact  # Remove nil values
  end
  
  # Get team user IDs based on user's assigned locations
  def get_team_user_ids
    return [user.id] unless user.uses_rbac?
    
    if user.effective_admin?
      # Company admins see everyone (only active users)
      company.users.where(status: 'active').pluck(:id)
    else
      # Location-tier users see users at their assigned locations
      location_ids = permission_service.accessible_location_ids
      
      if location_ids.any?
        # Get active users assigned to these locations
        User.where(id: UserLocation.where(location_id: location_ids).pluck(:user_id).uniq)
            .where(status: 'active')
            .pluck(:id)
      else
        [user.id]
      end
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
      # Meetings: Use start_time and end_time
      if activity.start_time.present? && activity.end_time.present?
        [activity.start_time, activity.end_time, false]
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
