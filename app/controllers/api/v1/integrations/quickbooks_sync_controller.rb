# frozen_string_literal: true

class Api::V1::Integrations::QuickbooksSyncController < ApplicationController
  before_action :set_company_scope
  
  def full
    return unless authorize_action!('settings', 'update')
    
    sync_service = QuickbooksSyncService.new(@company)
    results = sync_service.full_sync
    
    render json: { success: true, results: results }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
  
  def incremental
    return unless authorize_action!('settings', 'update')
    
    # Determine entity (company or location) based on params
    entity = if params[:location_id].present?
      @company.locations.find(params[:location_id])
    else
      @company
    end
    
    since = params[:since]&.to_datetime
    sync_service = QuickbooksSyncService.new(entity)
    result = sync_service.incremental_sync(since: since)
    
    if result[:success]
      render json: { success: true, message: result[:message] }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end
  
  def entity
    return unless authorize_action!('settings', 'update')
    
    sync_service = QuickbooksSyncService.new(@company)
    result = sync_service.sync_entity(params[:entity_type], params[:entity_id])
    
    if result[:success]
      render json: { success: true, mapping: result[:mapping] }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end
  
  def status
    return unless authorize_action!('settings', 'read')
    
    # Determine entity (company or location) based on scope and params
    entity = if params[:location_id].present?
      @company.locations.find(params[:location_id])
    elsif @company.quickbooks_scope == 'location'
      # If scope is location but no specific location requested, return company-level data
      @company
    else
      @company
    end
    
    # Get settings to check if auto_sync is enabled
    # CRITICAL: Use string keys since quickbooks_settings is stored as JSON
    settings = entity.quickbooks_settings || {}
    
    # Try both string and symbol keys to handle legacy data
    auto_sync_enabled = settings['auto_sync'] || settings[:auto_sync] || false
    
    # Get frequency for next sync calculation (default 15 minutes)
    auto_sync_frequency = settings['auto_sync_frequency'] || settings[:auto_sync_frequency] || 15
    
    Rails.logger.info "[QB Sync Status] Entity: #{entity.class.name} ##{entity.id}"
    Rails.logger.info "[QB Sync Status] Settings: #{settings.inspect}"
    Rails.logger.info "[QB Sync Status] Auto-sync enabled: #{auto_sync_enabled}"
    Rails.logger.info "[QB Sync Status] Last sync: #{entity.quickbooks_last_sync_at}"
    
    render json: {
      last_sync: entity.quickbooks_last_sync_at,
      sync_enabled: auto_sync_enabled,
      sync_frequency: auto_sync_frequency,
      stats: entity.respond_to?(:quickbooks_sync_stats) ? entity.quickbooks_sync_stats : {}
    }
  end
  
  def logs
    return unless authorize_action!('settings', 'read')
    
    logs = @company.quickbooks_sync_logs
      .includes(:quickbooks_sync_mapping)
      .order(created_at: :desc)
      .limit(params[:limit] || 50)
    
    if params[:status]
      logs = logs.where(status: params[:status])
    end
    
    if params[:entity_type]
      logs = logs.where(entity_type: params[:entity_type])
    end
    
    render json: logs
  end
  
  def mappings
    return unless authorize_action!('settings', 'read')
    
    mappings = @company.quickbooks_sync_mappings
      .order(last_synced_at: :desc)
      .limit(params[:limit] || 100)
    
    if params[:status]
      mappings = mappings.where(sync_status: params[:status])
    end
    
    if params[:entity_type]
      mappings = mappings.where(renter_insight_entity_type: params[:entity_type])
    end
    
    render json: mappings
  end
  
  def delete_mapping
    return unless authorize_action!('settings', 'update')
    
    mapping = @company.quickbooks_sync_mappings.find(params[:id])
    mapping.destroy
    
    render json: { success: true }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Mapping not found' }, status: :not_found
  end
  
  def retry_mapping
    return unless authorize_action!('settings', 'update')
    
    mapping = @company.quickbooks_sync_mappings.find(params[:id])
    mapping.reset_errors!
    
    sync_service = QuickbooksSyncService.new(@company)
    result = sync_service.sync_entity(mapping.renter_insight_entity_type, mapping.renter_insight_entity_id)
    
    if result[:success]
      render json: { success: true, mapping: result[:mapping] }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Mapping not found' }, status: :not_found
  end
end
