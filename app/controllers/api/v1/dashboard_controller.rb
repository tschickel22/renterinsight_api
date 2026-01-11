# frozen_string_literal: true

class Api::V1::DashboardController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/dashboard/presets
  # Returns available dashboard presets for current user
  def presets
    return unless authorize_action!('dashboard', 'read')

    available_presets = determine_available_presets

    render json: { presets: available_presets }
  end

  # GET /api/v1/dashboard/layout/:preset_id
  # Returns layout configuration for a preset (saved or default)
  def layout
    return unless authorize_action!('dashboard', 'read')

    preset_id = params[:preset_id]

    # Try to find saved custom layout
    saved_layout = DashboardLayout.find_by(
      user_id: current_user.id,
      company_id: @company.id,
      preset_id: preset_id
    )

    if saved_layout
      render json: { layout: saved_layout.as_json(except: [:created_at, :updated_at]) }
    else
      # Return empty - frontend will use default
      render json: { layout: nil }
    end
  end

  # POST /api/v1/dashboard/layout/:preset_id
  # Save custom layout for a preset
  def save_layout
    return unless authorize_action!('dashboard', 'write')

    preset_id = params[:preset_id]
    layout_data = params[:layout]

    # Find or create layout
    dashboard_layout = DashboardLayout.find_or_initialize_by(
      user_id: current_user.id,
      company_id: @company.id,
      preset_id: preset_id
    )

    dashboard_layout.layout_data = layout_data

    if dashboard_layout.save
      render json: { success: true }
    else
      render json: { 
        success: false, 
        errors: dashboard_layout.errors.full_messages 
      }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/dashboard/layout/:preset_id
  # Reset to default layout
  def reset_layout
    return unless authorize_action!('dashboard', 'write')

    preset_id = params[:preset_id]

    dashboard_layout = DashboardLayout.find_by(
      user_id: current_user.id,
      company_id: @company.id,
      preset_id: preset_id
    )

    if dashboard_layout
      dashboard_layout.destroy
      render json: { success: true }
    else
      render json: { success: true }
    end
  end

  # GET /api/v1/dashboard/metrics/:card_type
  # Generic endpoint for card data - will route to specific card services
  def metrics
    return unless authorize_action!('dashboard', 'read')

    card_type = params[:card_type]
    
    # Debug endpoint for top performers
    if card_type == 'top_performers_debug'
      debug_data = debug_top_performers
      render json: debug_data
      return
    end
    
    # Parse date range parameters
    date_range_params = {
      option: params[:date_range] || 'this_month',
      start_date: params[:start_date],
      end_date: params[:end_date]
    }

    # Initialize metrics service
    service = DashboardMetricsService.new(@company, current_user, date_range_params)

    # Route to appropriate card method
    data = case card_type
    when 'revenue_summary'
      # Check finance permission for revenue data
      return unless authorize_action!('dashboard_finance', 'read')
      service.revenue_summary
    when 'deals_count'
      # Check CRM deals permission
      return unless authorize_action!('deals', 'read')
      service.deals_count
    when 'leads_count'
      # Check CRM leads permission
      return unless authorize_action!('leads', 'read')
      service.leads_count
    when 'service_tickets_count'
      # Check service tickets permission
      return unless authorize_action!('service', 'read')
      service.service_tickets_count
    when 'accounts_receivable'
      # Check finance permission for A/R data
      return unless authorize_action!('dashboard_finance', 'read')
      service.accounts_receivable
    when 'accounts_payable'
      # Check finance permission for A/P data
      return unless authorize_action!('dashboard_finance', 'read')
      service.accounts_payable
    when 'payments_count'
      # Check finance permission for payments data
      return unless authorize_action!('dashboard_finance', 'read')
      service.payments_count
    when 'ar_aging_chart'
      # Check finance permission for A/R aging data
      return unless authorize_action!('dashboard_finance', 'read')
      service.ar_aging_chart
    when 'payment_methods_breakdown'
      # Check finance permission for payment methods data
      return unless authorize_action!('dashboard_finance', 'read')
      service.payment_methods_breakdown
    when 'recent_transactions'
      # Check finance permission for recent transactions
      return unless authorize_action!('dashboard_finance', 'read')
      service.recent_transactions
    when 'pipeline_funnel'
      # Check CRM deals permission for pipeline view
      return unless authorize_action!('deals', 'read')
      service.pipeline_funnel
    when 'revenue_trend'
      # Check finance permission for revenue trend
      return unless authorize_action!('dashboard_finance', 'read')
      service.revenue_trend
    when 'top_performers'
      # Check deals permission for performance data
      return unless authorize_action!('deals', 'read')
      service.top_performers
    when 'service_status_chart'
      # Check service tickets permission
      return unless authorize_action!('service', 'read')
      service.service_status_chart
    when 'recent_activities'
      # Recent activities across modules
      service.recent_activities
    when 'upcoming_tasks'
      # Upcoming tasks
      service.upcoming_tasks
    when 'unread_messages'
      # Unread notifications
      service.unread_messages
    when 'week_calendar'
      # Week calendar with tasks/events
      service.week_calendar
    when 'quick_actions'
      # Quick actions (permission-based on frontend)
      service.quick_actions
    else
      # Unknown card type
      { error: "Unknown card type: #{card_type}" }
    end

    render json: { data: data }
  rescue StandardError => e
    Rails.logger.error("Dashboard metrics error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    
    render json: { 
      error: 'Failed to load metrics',
      message: e.message 
    }, status: :internal_server_error
  end

  private

  def debug_top_performers
    # Get all closed_won deals
    closed_deals = @company.deals.where(stage: 'closed_won')
    
    # Get column info
    columns = @company.deals.column_names
    
    # Check for owner fields
    owner_fields = ['owner_id', 'user_id', 'assigned_to_id', 'salesperson_id', 'created_by_id']
    available_owner_fields = columns & owner_fields
    
    # Sample deal data
    sample_deals = closed_deals.limit(5).map do |deal|
      {
        id: deal.id,
        stage: deal.stage,
        value: deal.value,
        created_at: deal.created_at,
        owner_id: deal.respond_to?(:owner_id) ? deal.owner_id : nil,
        user_id: deal.respond_to?(:user_id) ? deal.user_id : nil
      }
    end
    
    # Try to get users for deals
    owner_field = available_owner_fields.first
    users_data = if owner_field
      closed_deals.where.not(owner_field => nil)
        .joins("LEFT JOIN users ON deals.#{owner_field} = users.id")
        .select("deals.id as deal_id, deals.#{owner_field} as owner_id, users.id as user_id, users.first_name, users.last_name, users.email")
        .limit(5)
        .map do |record|
          {
            deal_id: record.deal_id,
            owner_id: record.owner_id,
            user_id: record.user_id,
            user_name: "#{record.first_name} #{record.last_name}".strip,
            user_email: record.email
          }
        end
    else
      []
    end
    
    {
      summary: {
        total_closed_won: closed_deals.count,
        available_columns: columns,
        available_owner_fields: available_owner_fields,
        selected_owner_field: owner_field
      },
      sample_deals: sample_deals,
      sample_users: users_data
    }
  rescue StandardError => e
    {
      error: e.message,
      backtrace: e.backtrace.first(5)
    }
  end

  def determine_available_presets
    presets = []

    # Company Admin preset
    if current_user.has_permission?('dashboard_company_wide', 'read')
      presets << {
        id: 'company_admin',
        name: 'Company Overview',
        description: 'Full company metrics and analytics'
      }
    end

    # Finance preset
    if current_user.has_permission?('dashboard_finance', 'read')
      presets << {
        id: 'finance',
        name: 'Finance',
        description: 'Revenue, A/R, payments'
      }
    end

    # Location preset (default for most users)
    if current_user.has_permission?('dashboard', 'read')
      presets << {
        id: 'location',
        name: 'Location',
        description: 'Location-specific operations'
      }
    end

    # Sales Rep preset
    if current_user.has_permission?('deals', 'read')
      presets << {
        id: 'sales_rep',
        name: 'My Sales',
        description: 'Personal pipeline and performance'
      }
    end

    # Service Tech preset
    if current_user.has_permission?('service', 'read')
      presets << {
        id: 'service_tech',
        name: 'My Service',
        description: 'Assigned tickets and routes'
      }
    end

    presets
  end
end
