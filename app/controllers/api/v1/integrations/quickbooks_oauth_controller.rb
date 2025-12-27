# frozen_string_literal: true

class Api::V1::Integrations::QuickbooksOauthController < ApplicationController
  before_action :set_company_scope
  
  def authorize
    return unless authorize_action!('settings', 'update')
    
    oauth_service = QuickbooksOauthService.new(@company)
    state_token = SecureRandom.hex(32)
    session[:qb_oauth_state] = state_token
    
    redirect_uri = "#{request.base_url}/api/v1/integrations/quickbooks/callback"
    auth_url = oauth_service.authorization_url(redirect_uri, state_token)
    
    render json: { authorization_url: auth_url }
  end
  
  def callback
    return render json: { error: 'Invalid state' }, status: :bad_request if params[:state] != session[:qb_oauth_state]
    
    company = Company.find_by(id: session[:company_id])
    return render json: { error: 'Company not found' }, status: :not_found unless company
    
    oauth_service = QuickbooksOauthService.new(company)
    redirect_uri = "#{request.base_url}/api/v1/integrations/quickbooks/callback"
    
    result = oauth_service.exchange_code_for_tokens!(params[:code], redirect_uri)
    
    if result[:success]
      company.update!(
        quickbooks_realm_id: params[:realmId],
        quickbooks_sync_enabled: true
      )
      
      redirect_to "#{ENV['FRONTEND_URL']}/settings/integrations?qb_connected=true"
    else
      redirect_to "#{ENV['FRONTEND_URL']}/settings/integrations?qb_error=#{CGI.escape(result[:error])}"
    end
  end
  
  def status
    return unless authorize_action!('settings', 'read')
    
    render json: {
      connected: @company.quickbooks_connected?,
      realm_id: @company.quickbooks_realm_id,
      connected_at: @company.quickbooks_connected_at,
      last_sync_at: @company.quickbooks_last_sync_at,
      token_expires_at: @company.quickbooks_token_expires_at,
      sync_enabled: @company.quickbooks_sync_enabled
    }
  end
  
  def disconnect
    return unless authorize_action!('settings', 'update')
    
    oauth_service = QuickbooksOauthService.new(@company)
    result = oauth_service.revoke_token!
    
    if result[:success]
      render json: { success: true, message: 'Disconnected from QuickBooks' }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end
  
  def refresh_token
    return unless authorize_action!('settings', 'update')
    
    result = @company.refresh_quickbooks_token!
    
    if result[:success]
      render json: { success: true, expires_at: result[:expires_at] }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end
end
