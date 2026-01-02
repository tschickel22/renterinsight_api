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
#   - 'my': User's own calendar (view_own permission)
#   - 'team': Team calendars based on assigned locations (view_team permission)
#   - 'service_all': All service tickets (view_service_all permission)
#   - 'service_unassigned': Unassigned service tickets (view_service_unassigned permission)
#   - 'all': All company calendars (view_all permission)

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
    case view
    when 'my'
      # Check for 'own' scope first, then fall back to 'all' (broader scope)
      permission_service.can?('calendar', 'view_own', 'own') ||
        permission_service.can?('calendar', 'view_own', 'all')
    when 'team'
      # Check for 'assigned_locations' first, then fall back to 'all'
      permission_service.can?('calendar', 'view_team', 'assigned_locations') ||
        permission_service.can?('calendar', 'view_team', 'all')
    when 'service_all'
      permission_service.can?('calendar', 'view_service_all', 'assigned_locations') ||
        permission_service.can?('calendar', 'view_service_all', 'all')
    when 'service_unassigned'
      permission_service.can?('calendar', 'view_service_unassigned', 'assigned_locations') ||
        permission_service.can?('calendar', 'view_service_unassigned', 'all')
    when 'all'
      permission_service.can?('calendar', 'view_all', 'all')
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
    
    # Lead Activities - check assigned_locations or all scope
    if permission_service.can?('leads', 'read', 'assigned_locations') ||
       permission_service.can?('leads', 'read', 'all')
      activities += load_lead_activities(view)
    end
    
    # Account Activities
    if permission_service.can?('crm', 'read', 'assigned_locations') ||
       permission_service.can?('crm', 'read', 'all')
      activities += load_account_activities(view)
    end
    
    # Contact Activities
    if permission_service.can?('crm', 'read', 'assigned_locations') ||
       permission_service.can?('crm', 'read', 'all')
      activities += load_contact_activities(view)
    end
    
    # Deal Activities
    if permission_service.can?('deals', 'read', 'assigned_locations') ||
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
    
    activities.map { |activity| activity_to_event(activity, 'lead') }
  end
  
  # Load account activities
  def load_account_activities(view)
    activities = AccountActivity.joins(:account).where(accounts: {company_id: company.id})
    activities = activities.includes(:account, :assigned_to)
    activities = filter_activities_by_view(activities, view)
    
    activities.map { |activity| activity_to_event(activity, 'account') }
  end
  
  # Load contact activities
  def load_contact_activities(view)
    activities = ContactActivity.joins(:contact).where(contacts: {company_id: company.id})
    activities = activities.includes(:contact, :assigned_to)
    activities = filter_activities_by_view(activities, view)
    
    activities.map { |activity| activity_to_event(activity, 'contact') }
  end
  
  # Load deal activities
  def load_deal_activities(view)
    activities = DealActivity.joins(:deal).where(deals: {company_id: company.id})
    activities = activities.includes(:deal, :assigned_to)
    activities = filter_activities_by_view(activities, view)
    
    activities.map { |activity| activity_to_event(activity, 'deal') }
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
      # Apply location filter if active through parent table
      if Current.location_filtered?
        parent_table = get_parent_table_name(activities)
        activities = activities.where("#{parent_table}.location_id" => Current.location_id)
      end
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
    return [] unless permission_service.can?('service', 'read', 'assigned_locations') ||
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
      # All service tickets at accessible locations
      if Current.location_filtered?
        tickets.where(location_id: Current.location_id)
      elsif permission_service.accessible_location_ids.any?
        tickets.where(location_id: permission_service.accessible_location_ids)
      else
        tickets
      end
    when 'service_unassigned'
      # Unassigned tickets at accessible locations
      base = tickets.where(assigned_to: [nil, ''])
      if Current.location_filtered?
        base.where(location_id: Current.location_id)
      elsif permission_service.accessible_location_ids.any?
        base.where(location_id: permission_service.accessible_location_ids)
      else
        base
      end
    when 'all'
      if Current.location_filtered?
        tickets.where(location_id: Current.location_id)
      else
        tickets
      end
    else
      tickets.where(assigned_to: user.id.to_s)
    end
    
    tickets.map { |ticket| service_ticket_to_event(ticket) }
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
    
    # Determine start/end times
    start_time = activity.start_time || activity.due_date&.beginning_of_day
    end_time = activity.end_time || activity.due_date&.end_of_day
    
    # Color by activity type
    color = activity_color(activity.activity_type)
    
    {
      id: "#{source_type}-activity-#{activity.id}",
      title: activity.subject,
      type: activity.activity_type,
      start: start_time,
      end: end_time,
      all_day: activity.start_time.nil?,
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
  
  # Convert service ticket to unified event format
  def service_ticket_to_event(ticket)
    {
      id: "service-ticket-#{ticket.id}",
      title: ticket.title,
      type: 'service_ticket',
      start: ticket.scheduled_date&.beginning_of_day,
      end: ticket.scheduled_date&.end_of_day,
      all_day: true,
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
