# frozen_string_literal: true

module Api
  module V1
    class CalendarController < ApplicationController
      include RbacAuthorization
      
      before_action :set_company_scope
      
      # GET /api/v1/calendar/events
      #
      # Query Parameters:
      #   view: 'my' | 'team' | 'service_all' | 'service_unassigned' | 'all'
      #   start_date: ISO date (e.g., '2026-01-01')
      #   end_date: ISO date (e.g., '2026-01-31')
      #   types[]: Array of event types ['task', 'meeting', 'call', 'reminder', 'service_ticket']
      #   status: Filter by status
      #   priority: Filter by priority
      #   assigned_to: Filter by assigned user ID
      #   hide_completed: 'true' to drop completed/cancelled events
      #   hide_past: 'true' to drop events that have already ended
      #
      # Returns: Array of unified calendar events
      def events
        # Validate view parameter
        view = params[:view] || 'my'
        
        unless valid_view?(view)
          return render json: { error: 'Invalid view parameter' }, status: :bad_request
        end
        
        # Check permission for requested view
        Rails.logger.info "[CalendarController#events] Checking can_view?(#{view}) for user #{current_user.email}"
        can_view_result = can_view?(view)
        Rails.logger.info "[CalendarController#events] can_view?(#{view}) returned: #{can_view_result}"
        
        unless can_view_result
          Rails.logger.error "[CalendarController#events] Permission denied for view '#{view}'"
        return render json: { 
          error: 'Forbidden', 
          message: "You don't have permission to access this calendar view" 
        }, status: :forbidden
      end
        
        # Get aggregated events
        service = CalendarService.new(current_user, @company, calendar_params)
        events = service.aggregated_events
        
        Rails.logger.info "[CalendarController#events] User: #{current_user.email}, View: #{view}, Events count: #{events.count}"
      
      render json: { events: events }, status: :ok
        
      rescue => e
        Rails.logger.error "[CalendarController#events] #{e.class}: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        render json: { 
          error: 'Failed to load calendar events', 
          message: e.message 
        }, status: :internal_server_error
      end
      
      # GET /api/v1/calendar/views
      #
      # Returns available calendar views based on user's permissions
      def available_views
        views = []
        
        # Platform/super admins get all views
        if current_user.platform_admin? || current_user.super_admin?
          views = [
            { id: 'my', name: 'My Calendar', description: 'Your personal calendar and activities', icon: 'User' },
            { id: 'team', name: 'Team Calendar', description: 'Calendars of your team members', icon: 'Users' },
            { id: 'service_all', name: 'All Service Tickets', description: 'All scheduled service tickets', icon: 'Wrench' },
            { id: 'service_unassigned', name: 'Unassigned Tickets', description: 'Service tickets needing assignment', icon: 'AlertCircle' },
            { id: 'all', name: 'All Company', description: 'All company calendars and activities', icon: 'Building' }
          ]
          return render json: { views: views }, status: :ok
        end
        
        # For non-RBAC companies, provide default views
        unless @company&.use_rbac_system
          views = [
            { id: 'my', name: 'My Calendar', description: 'Your personal calendar and activities', icon: 'User' },
            { id: 'team', name: 'Team Calendar', description: 'Calendars of your team members', icon: 'Users' }
          ]
          return render json: { views: views }, status: :ok
        end
        
        # For RBAC users, check permissions
        permission_service = PermissionService.new(current_user)
        
        views = []
        
        # My Calendar - everyone with read/own permission
        if permission_service.can?('calendar', 'read', 'own')
          views << {
            id: 'my',
            name: 'My Calendar',
            description: 'Your personal calendar and activities',
            icon: 'User'
          }
        end
        
        # Team Calendar - users with read/assigned_locations permission
        if permission_service.can?('calendar', 'read', 'assigned_locations')
          views << {
            id: 'team',
            name: 'Team Calendar',
            description: 'Calendars of your team members',
            icon: 'Users'
          }
        end
        
        # All Service Tickets - users with manage/all permission
        if permission_service.can?('calendar', 'manage', 'all')
          views << {
            id: 'service_all',
            name: 'All Service Tickets',
            description: 'All scheduled service tickets',
            icon: 'Wrench'
          }
        end
        
        # Unassigned Service Tickets - users with delete/all permission
        if permission_service.can?('calendar', 'delete', 'all')
          views << {
            id: 'service_unassigned',
            name: 'Unassigned Tickets',
            description: 'Service tickets needing assignment',
            icon: 'AlertCircle'
          }
        end
        
        # All Company Calendar - admins with read/all permission
        if permission_service.can?('calendar', 'read', 'all')
          views << {
            id: 'all',
            name: 'All Company',
            description: 'All company calendars and activities',
            icon: 'Building'
          }
        end
        
        render json: { views: views }, status: :ok
        
      rescue => e
        Rails.logger.error "[CalendarController#available_views] #{e.class}: #{e.message}"
        render json: { 
          error: 'Failed to load available views', 
          message: e.message 
        }, status: :internal_server_error
      end
      
      # GET /api/v1/calendar/stats
      #
      # Returns calendar statistics for the current view
      def stats
      view = params[:view] || 'my'
      
      Rails.logger.info "[CalendarController#stats] Checking can_view?(#{view}) for user #{current_user.email}"
      can_view_result = can_view?(view)
      Rails.logger.info "[CalendarController#stats] can_view?(#{view}) returned: #{can_view_result}"
      
      unless can_view_result
        Rails.logger.error "[CalendarController#stats] Permission denied for view '#{view}'"
        return render json: { error: 'Forbidden' }, status: :forbidden
      end
        
        service = CalendarService.new(current_user, @company, calendar_params)
        events = service.aggregated_events
        
        stats = {
          total_events: events.count,
          by_type: events.group_by { |e| e[:type] }.transform_values(&:count),
          by_status: events.group_by { |e| e[:status] }.transform_values(&:count),
          by_priority: events.group_by { |e| e[:priority] }.transform_values(&:count),
          upcoming: events.select { |e| e[:start] && e[:start] >= Time.current }.count,
          overdue: events.select { |e| e[:end] && e[:end] < Time.current && e[:status] != 'completed' }.count
        }
        
        render json: stats, status: :ok
        
      rescue => e
        Rails.logger.error "[CalendarController#stats] #{e.class}: #{e.message}"
        render json: { 
          error: 'Failed to load calendar stats', 
          message: e.message 
        }, status: :internal_server_error
      end
      
      private
      
      def calendar_params
        params.permit(:view, :start_date, :end_date, :status, :priority, :assigned_to,
                      :hide_completed, :hide_past, types: [], location_ids: [])
      end
      
      def valid_view?(view)
        %w[my team service_all service_unassigned all].include?(view)
      end
      
      def can_view?(view)
      Rails.logger.info "[can_view?] View: #{view}, User: #{current_user.email}, Platform Admin: #{current_user.platform_admin?}"
      
      # Platform admins and super admins can view all
      return true if current_user.platform_admin?
      return true if current_user.super_admin?
      
      # Company admins (effective_admin) get full calendar access
      if current_user.effective_admin?
        Rails.logger.info "[can_view?] User is company admin - granting access"
        return true
      end
      
      # If current company doesn't use RBAC, allow all access
      Rails.logger.info "[can_view?] Company uses RBAC: #{@company&.use_rbac_system}"
      return true unless @company&.use_rbac_system
      
      Rails.logger.info "[can_view?] Creating PermissionService for user #{current_user.id}"
      permission_service = PermissionService.new(current_user)
        
        # Calendar permissions use standard actions (read/manage/delete) with different scopes
        # As defined in Resource model's calendar_permission_groups:
        # - 'read' with 'own' = view personal calendar
        # - 'read' with 'assigned_locations' = view team calendars
        # - 'read' with 'all' = view all company calendars
        # - 'manage' with 'all' = view all service tickets
        # - 'delete' with 'all' = view unassigned service tickets
        result = case view
        when 'my'
          permission_service.can?('calendar', 'read', 'own')
        when 'team'
          permission_service.can?('calendar', 'read', 'assigned_locations')
        when 'service_all'
          permission_service.can?('calendar', 'manage', 'all')
        when 'service_unassigned'
          permission_service.can?('calendar', 'delete', 'all')
        when 'all'
          permission_service.can?('calendar', 'read', 'all')
        else
        false
        end
      
      Rails.logger.info "[can_view?] Permission check for view '#{view}': #{result}"
      result
      end
    end
  end
end
