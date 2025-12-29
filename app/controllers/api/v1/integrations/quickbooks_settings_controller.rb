# frozen_string_literal: true

class Api::V1::Integrations::QuickbooksSettingsController < ApplicationController
  before_action :set_company_scope
  
  # GET /api/v1/integrations/quickbooks/settings
  def show
    return unless authorize_action!('settings', 'read')
    
    entity = determine_quickbooks_entity
    return render json: { error: 'Entity not found' }, status: :not_found unless entity
    
    # Return empty settings if none exist yet
    settings = entity.resolved_quickbooks_settings || {}
    
    render json: {
      settings: settings,
      scope: @company.quickbooks_scope,
      entity_type: entity.is_a?(Location) ? 'location' : 'company',
      entity_name: entity.is_a?(Location) ? entity.name : @company.name
    }
  end
  
  # PUT/PATCH /api/v1/integrations/quickbooks/settings
  def update
    return unless authorize_action!('settings', 'update')
    
    # Handle scope update separately
    if params[:scope].present?
      unless @company.update(quickbooks_scope: params[:scope])
        return render json: { 
          error: 'Failed to update scope', 
          details: @company.errors.full_messages 
        }, status: :unprocessable_entity
      end
      
      return render json: { success: true, scope: @company.quickbooks_scope }
    end
    
    # Handle settings update
    entity = determine_quickbooks_entity
    return render json: { error: 'Entity not found' }, status: :not_found unless entity
    
    new_settings = params[:settings].permit!.to_h
    
    begin
      entity.update_quickbooks_settings!(new_settings)
      
      render json: { 
        success: true,
        settings: entity.resolved_quickbooks_settings
      }
    rescue => e
      Rails.logger.error "QuickBooks settings update error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
  
  # GET /api/v1/integrations/quickbooks/settings/entity/:entity_type
  def entity_settings
    return unless authorize_action!('settings', 'read')
    
    entity = determine_quickbooks_entity
    return render json: { error: 'Entity not found' }, status: :not_found unless entity
    
    entity_type = params[:entity_type]
    all_settings = entity.resolved_quickbooks_settings
    
    entity_config = all_settings.dig(:entities, entity_type.to_sym) || {}
    
    render json: {
      entity_type: entity_type,
      settings: entity_config,
      available_sync_directions: ['to_qb', 'from_qb', 'bidirectional'],
      available_frequencies: [
        { value: 15, label: '15 minutes' },
        { value: 30, label: '30 minutes' },
        { value: 60, label: '1 hour' },
        { value: 240, label: '4 hours' },
        { value: 1440, label: 'Daily' }
      ]
    }
  end
  
  # PUT /api/v1/integrations/quickbooks/settings/entity/:entity_type
  def update_entity_settings
    return unless authorize_action!('settings', 'update')
    
    entity = determine_quickbooks_entity
    return render json: { error: 'Entity not found' }, status: :not_found unless entity
    
    entity_type = params[:entity_type]
    new_entity_settings = params[:entity_settings].permit!.to_h
    
    # Get current settings and deep_dup to make it mutable
    current_settings = entity.resolved_quickbooks_settings.deep_dup
    
    # Update the specific entity settings
    current_settings[:entities] ||= {}
    current_settings[:entities][entity_type.to_sym] = new_entity_settings.deep_symbolize_keys
    
    begin
      entity.update_quickbooks_settings!(current_settings)
      
      render json: {
        success: true,
        settings: current_settings.dig(:entities, entity_type.to_sym)
      }
    rescue => e
      Rails.logger.error "Entity settings update error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
  
  # POST /api/v1/integrations/quickbooks/settings/test
  def test_connection
    return unless authorize_action!('settings', 'read')
    
    entity = determine_quickbooks_entity
    return render json: { error: 'Entity not found' }, status: :not_found unless entity
    return render json: { error: 'Not connected to QuickBooks' }, status: :unprocessable_entity unless entity.quickbooks_connected?
    
    # Refresh token if expired
    if entity.quickbooks_token_expired?
      result = entity.refresh_quickbooks_token!
      return render json: { error: 'Token refresh failed', details: result[:error] }, status: :unprocessable_entity unless result[:success]
    end
    
    # Test API connection by getting company info
    begin
      api = QuickbooksApiService.new(entity)
      company_info = api.get_company_info
      
      render json: {
        success: true,
        message: 'Connection successful',
        company_info: company_info
      }
    rescue => e
      Rails.logger.error "QB connection test failed: #{e.message}"
      render json: {
        success: false,
        error: 'Connection test failed',
        details: e.message
      }, status: :unprocessable_entity
    end
  end
  
  # GET /api/v1/integrations/quickbooks/settings/mappings
  def field_mappings
    return unless authorize_action!('settings', 'read')
    
    entity_type = params[:entity_type]
    location_id = params[:location_id]
    
    mappings = if entity_type.present?
      QuickbooksFieldMappingsService.get_mappings_for_entity(
        @company,
        entity_type,
        location_id: location_id
      )
    else
      @company.quickbooks_field_mappings.enabled.by_priority
    end
    
    render json: {
      mappings: mappings.as_json(
        only: [:id, :entity_type, :renter_insight_field, :quickbooks_field, :mapping_type, :transformation_logic, :enabled, :priority]
      )
    }
  end
  
  # POST /api/v1/integrations/quickbooks/settings/mappings
  def create_field_mapping
    return unless authorize_action!('settings', 'update')
    
    mapping = @company.quickbooks_field_mappings.build(field_mapping_params)
    
    if mapping.save
      render json: {
        success: true,
        mapping: mapping.as_json(
          only: [:id, :entity_type, :renter_insight_field, :quickbooks_field, :mapping_type, :transformation_logic, :enabled, :priority]
        )
      }, status: :created
    else
      render json: { error: mapping.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end
  
  # PUT /api/v1/integrations/quickbooks/settings/mappings/:id
  def update_field_mapping
    return unless authorize_action!('settings', 'update')
    
    mapping = @company.quickbooks_field_mappings.find(params[:id])
    
    if mapping.update(field_mapping_params)
      render json: {
        success: true,
        mapping: mapping.as_json(
          only: [:id, :entity_type, :renter_insight_field, :quickbooks_field, :mapping_type, :transformation_logic, :enabled, :priority]
        )
      }
    else
      render json: { error: mapping.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Mapping not found' }, status: :not_found
  end
  
  # DELETE /api/v1/integrations/quickbooks/settings/mappings/:id
  def delete_field_mapping
    return unless authorize_action!('settings', 'update')
    
    mapping = @company.quickbooks_field_mappings.find(params[:id])
    mapping.destroy
    
    render json: { success: true }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Mapping not found' }, status: :not_found
  end
  
  # POST /api/v1/integrations/quickbooks/settings/mappings/defaults
  def create_default_mappings
    return unless authorize_action!('settings', 'update')
    
    location_id = params[:location_id]
    
    if location_id.present?
      location = @company.locations.find(location_id)
      QuickbooksFieldMappingsService.create_defaults_for_location(location)
    else
      QuickbooksFieldMappingsService.create_defaults_for_company(@company)
    end
    
    render json: { success: true, message: 'Default mappings created successfully' }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Location not found' }, status: :not_found
  rescue => e
    Rails.logger.error "Failed to create default mappings: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end
  
  # GET /api/v1/integrations/quickbooks/settings/sync_logs
  def sync_logs
    return unless authorize_action!('settings', 'read')
    
    location_id = params[:location_id]
    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 50).to_i.clamp(1, 100)
    
    # Base query
    logs = @company.quickbooks_sync_logs
    
    # Filter by location if specified
    logs = logs.where(location_id: location_id) if location_id.present?
    
    # Filter by entity type
    logs = logs.for_entity(params[:entity_type]) if params[:entity_type].present?
    
    # Filter by status
    case params[:status]
    when 'success'
      logs = logs.successful
    when 'error', 'failed'
      logs = logs.failed
    when 'pending'
      logs = logs.pending
    end
    
    # Filter by date range
    if params[:start_date].present?
      logs = logs.where('created_at >= ?', Date.parse(params[:start_date]).beginning_of_day)
    end
    if params[:end_date].present?
      logs = logs.where('created_at <= ?', Date.parse(params[:end_date]).end_of_day)
    end
    
    # Order by most recent first
    logs = logs.order(created_at: :desc)
    
    # Paginate
    total_count = logs.count
    logs = logs.offset((page - 1) * per_page).limit(per_page)
    
    render json: {
      logs: logs.as_json(
        only: [:id, :operation, :entity_type, :entity_id, :sync_direction, :status, 
               :error_message, :duration_ms, :started_at, :completed_at, :created_at],
        methods: [:duration_seconds]
      ),
      pagination: {
        page: page,
        per_page: per_page,
        total_count: total_count,
        total_pages: (total_count.to_f / per_page).ceil
      },
      stats: {
        success_rate: @company.quickbooks_sync_logs.success_rate(30.days),
        average_duration: @company.quickbooks_sync_logs.average_duration(30.days)
      }
    }
  end
  
  # GET /api/v1/integrations/quickbooks/settings/sync_logs/:id
  def sync_log_details
    return unless authorize_action!('settings', 'read')
    
    log = @company.quickbooks_sync_logs.find(params[:id])
    
    render json: {
      log: log.as_json(
        only: [:id, :operation, :entity_type, :entity_id, :sync_direction, :status,
               :error_message, :request_data, :response_data, :duration_ms,
               :started_at, :completed_at, :created_at],
        methods: [:duration_seconds],
        include: {
          location: { only: [:id, :name] }
        }
      )
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Sync log not found' }, status: :not_found
  end
  
  # POST /api/v1/integrations/quickbooks/sync/entity
  def sync_entity
    return unless authorize_action!('settings', 'update')
    
    entity = determine_quickbooks_entity
    return render json: { error: 'Entity not found' }, status: :not_found unless entity
    return render json: { error: 'Not connected to QuickBooks' }, status: :unprocessable_entity unless entity.quickbooks_connected?
    
    entity_type = params[:entity_type]
    entity_ids = params[:entity_ids] # Optional - sync specific records
    direction = params[:direction] # Optional - override configured direction
    
    begin
      sync_service = QuickbooksSyncService.new(entity)
      result = sync_service.sync_entity_type(entity_type, direction: direction, entity_ids: entity_ids)
      
      if result[:success]
        render json: {
          success: true,
          message: "Successfully synced #{entity_type}",
          log_id: result[:log].id,
          result: result[:result]
        }
      else
        render json: {
          success: false,
          error: result[:error],
          log_id: result[:log]&.id
        }, status: :unprocessable_entity
      end
      
    rescue => e
      Rails.logger.error "Sync error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
  
  # POST /api/v1/integrations/quickbooks/sync/all
  def sync_all_entities
    return unless authorize_action!('settings', 'update')
    
    entity = determine_quickbooks_entity
    return render json: { error: 'Entity not found' }, status: :not_found unless entity
    return render json: { error: 'Not connected to QuickBooks' }, status: :unprocessable_entity unless entity.quickbooks_connected?
    
    direction = params[:direction] # Optional - override configured direction
    
    begin
      sync_service = QuickbooksSyncService.new(entity)
      results = sync_service.sync_all_entities(direction: direction)
      
      # Count successes and failures
      successes = results.count { |_, r| r[:success] }
      failures = results.count { |_, r| !r[:success] }
      
      render json: {
        success: failures == 0,
        message: "Synced #{successes} entity types, #{failures} failed",
        results: results
      }
      
    rescue => e
      Rails.logger.error "Sync all error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
  
  private
  
  def determine_quickbooks_entity
    if params[:location_id].present?
      @company.locations.find_by(id: params[:location_id])
    elsif @company.quickbooks_scope == 'location'
      nil
    else
      @company
    end
  end
  
  def field_mapping_params
    params.require(:mapping).permit(
      :location_id,
      :entity_type,
      :renter_insight_field,
      :quickbooks_field,
      :mapping_type,
      :transformation_logic,
      :enabled,
      :priority
    )
  end
end
