# frozen_string_literal: true

class Api::V1::Integrations::QuickbooksSettingsController < ApplicationController
  before_action :set_company_scope
  
  def show
    return unless authorize_action!('settings', 'read')
    
    render json: {
      settings: @company.resolved_quickbooks_settings,
      connected: @company.quickbooks_connected?,
      realm_id: @company.quickbooks_realm_id
    }
  end
  
  def update
    return unless authorize_action!('settings', 'update')
    
    @company.update_quickbooks_settings!(settings_params)
    
    render json: {
      success: true,
      settings: @company.resolved_quickbooks_settings
    }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
  
  def destroy
    return unless authorize_action!('settings', 'update')
    
    @company.update_quickbooks_settings!({})
    
    render json: { success: true }
  end
  
  def accounts
    return unless authorize_action!('settings', 'read')
    return render json: { error: 'Not connected' }, status: :bad_request unless @company.quickbooks_connected?
    
    api_service = QuickbooksApiService.new(@company)
    result = api_service.get_accounts
    
    if result[:success]
      accounts = result[:data]['QueryResponse']['Account'] || []
      render json: { accounts: accounts }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end
  
  def test_connection
    return unless authorize_action!('settings', 'read')
    return render json: { error: 'Not connected' }, status: :bad_request unless @company.quickbooks_connected?
    
    api_service = QuickbooksApiService.new(@company)
    result = api_service.get_company_info
    
    if result[:success]
      company_info = result[:data]['CompanyInfo']
      render json: {
        success: true,
        company_name: company_info['CompanyName'],
        realm_id: company_info['Id']
      }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end
  
  def entity_settings
    return unless authorize_action!('settings', 'read')
    
    entity_type = params[:entity_type]
    settings = @company.resolved_quickbooks_settings[:entities][entity_type.to_sym]
    
    render json: { settings: settings }
  end
  
  def update_entity_settings
    return unless authorize_action!('settings', 'update')
    
    entity_type = params[:entity_type]
    current_settings = @company.resolved_quickbooks_settings
    current_settings[:entities][entity_type.to_sym] = entity_settings_params
    
    @company.update_quickbooks_settings!(current_settings)
    
    render json: { success: true, settings: current_settings[:entities][entity_type.to_sym] }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
  
  def field_mappings
    return unless authorize_action!('settings', 'read')
    
    mappings = @company.quickbooks_field_mappings
    mappings = mappings.for_entity(params[:entity_type]) if params[:entity_type]
    
    render json: { mappings: mappings }
  end
  
  def create_field_mapping
    return unless authorize_action!('settings', 'update')
    
    mapping = @company.quickbooks_field_mappings.create!(field_mapping_params)
    
    render json: { success: true, mapping: mapping }, status: :created
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
  
  def update_field_mapping
    return unless authorize_action!('settings', 'update')
    
    mapping = @company.quickbooks_field_mappings.find(params[:id])
    mapping.update!(field_mapping_params)
    
    render json: { success: true, mapping: mapping }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Mapping not found' }, status: :not_found
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
  
  def delete_field_mapping
    return unless authorize_action!('settings', 'update')
    
    mapping = @company.quickbooks_field_mappings.find(params[:id])
    mapping.destroy
    
    render json: { success: true }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Mapping not found' }, status: :not_found
  end
  
  private
  
  def settings_params
    params.require(:settings).permit!
  end
  
  def entity_settings_params
    params.require(:settings).permit!
  end
  
  def field_mapping_params
    params.require(:mapping).permit(
      :entity_type, :renter_insight_field, :quickbooks_field,
      :mapping_type, :transformation_logic, :enabled, :priority
    )
  end
end
