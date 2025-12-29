# frozen_string_literal: true

class Api::V1::Platform::QuickbooksSettingsController < ApplicationController
  before_action :require_platform_admin
  
  def show
    settings = Setting.find_by(key: 'quickbooks_platform_settings')
    
    render json: {
      settings: settings&.value || default_platform_settings
    }
  end
  
  def update
    setting = Setting.find_or_initialize_by(key: 'quickbooks_platform_settings')
    setting.value = platform_settings_params
    setting.save!
    
    render json: { success: true, settings: setting.value }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
  
  def stats
    stats = {
      total_companies: Company.with_quickbooks_enabled.count,
      total_syncs_today: QuickbooksSyncLog.where('created_at >= ?', Time.current.beginning_of_day).count,
      success_rate: QuickbooksSyncLog.success_rate(24.hours),
      avg_duration: QuickbooksSyncLog.average_duration(24.hours),
      active_mappings: QuickbooksSyncMapping.active.count,
      error_mappings: QuickbooksSyncMapping.with_errors.count
    }
    
    render json: { stats: stats }
  end
  
  def companies
    companies = Company.with_quickbooks_enabled
      .select(:id, :name, :quickbooks_realm_id, :quickbooks_connected_at, :quickbooks_last_sync_at)
    
    render json: { companies: companies }
  end
  
  def logs
    logs = QuickbooksSyncLog
      .includes(:company)
      .order(created_at: :desc)
      .limit(params[:limit] || 100)
    
    if params[:company_id]
      logs = logs.where(company_id: params[:company_id])
    end
    
    if params[:status]
      logs = logs.where(status: params[:status])
    end
    
    render json: logs.as_json(include: { company: { only: [:id, :name] } })
  end
  
  def sync_all
    companies = Company.with_quickbooks_enabled
    
    companies.find_each do |company|
      QuickbooksAutoSyncJob.perform_later(company.id)
    end
    
    render json: { success: true, message: "Queued sync for #{companies.count} companies" }
  end
  
  private
  
  def require_platform_admin
    return render json: { error: 'Unauthorized' }, status: :unauthorized unless current_user&.platform_admin?
  end
  
  def platform_settings_params
    params.require(:settings).permit(
      :client_id, :client_secret, :environment, :webhook_verifier_token,
      default_mappings: {}
    )
  end
  
  def default_platform_settings
    {
      environment: 'sandbox',
      default_mappings: {
        inventory: { enabled: false },
        customers: { enabled: false },
        invoices: { enabled: false },
        payments: { enabled: false }
      }
    }
  end
end
