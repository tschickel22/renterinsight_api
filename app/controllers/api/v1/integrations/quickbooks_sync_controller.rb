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
    
    since = params[:since]&.to_datetime
    sync_service = QuickbooksSyncService.new(@company)
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
    
    stats = @company.quickbooks_sync_stats
    
    render json: {
      last_sync: @company.quickbooks_last_sync_at,
      sync_enabled: @company.quickbooks_sync_enabled,
      stats: stats
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
