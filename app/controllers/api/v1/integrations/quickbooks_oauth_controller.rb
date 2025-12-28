# frozen_string_literal: true

class Api::V1::Integrations::QuickbooksOauthController < ApplicationController
  before_action :set_company_scope, except: [:callback]
  skip_before_action :authenticate, only: [:callback]
  
  def authorize
    return unless authorize_action!('settings', 'update')
    
    # Determine entity based on company scope
    entity = determine_quickbooks_entity
    return render json: { error: 'Location required for location-scoped QuickBooks' }, status: :bad_request unless entity
    
    oauth_service = QuickbooksOauthService.new(entity)
    state_token = SecureRandom.hex(32)
    session[:qb_oauth_state] = state_token
    session[:qb_company_id] = @company.id
    session[:qb_location_id] = params[:location_id] if params[:location_id].present?
    session[:qb_return_url] = params[:return_url] if params[:return_url].present? # Store return URL
    
    # Redirect to FRONTEND callback page (not backend)
    frontend_url = ENV['FRONTEND_URL'] || 'https://localhost:5173'
    redirect_uri = "#{frontend_url}/integrations/quickbooks/callback"
    
    auth_url = oauth_service.authorization_url(redirect_uri, state_token)
    
    render json: { auth_url: auth_url }
  end
  
  def callback
    # Validate state token
    return render json: { error: 'Invalid state' }, status: :bad_request if params[:state] != session[:qb_oauth_state]
    
    # Get company from session (stored in authorize action)
    company = Company.find_by(id: session[:qb_company_id])
    return render json: { error: 'Company not found' }, status: :not_found unless company
    
    # Get return URL from session
    return_url = session[:qb_return_url]
    
    # Determine entity based on session
    entity = if session[:qb_location_id].present?
      company.locations.find_by(id: session[:qb_location_id])
    else
      company
    end
    return render json: { error: 'Entity not found' }, status: :not_found unless entity
    
    Rails.logger.info "[QB Callback] Entity before OAuth: #{entity.class.name}##{entity.id}"
    Rails.logger.info "[QB Callback] Token expires at BEFORE: #{entity.quickbooks_token_expires_at.inspect}"
    
    oauth_service = QuickbooksOauthService.new(entity)
    
    # Use FRONTEND callback URI (same as what we sent to QuickBooks)
    frontend_url = ENV['FRONTEND_URL'] || 'https://localhost:5173'
    redirect_uri = "#{frontend_url}/integrations/quickbooks/callback"
    
    result = oauth_service.exchange_code_for_tokens!(params[:code], redirect_uri)
    
    Rails.logger.info "[QB Callback] OAuth result: #{result.inspect}"
    
    if result[:success]
      # Reload entity to see if tokens were stored
      entity.reload
      Rails.logger.info "[QB Callback] Token expires at AFTER reload: #{entity.quickbooks_token_expires_at.inspect}"
      Rails.logger.info "[QB Callback] Connected at AFTER reload: #{entity.quickbooks_connected_at.inspect}"
      
      entity.update!(
        quickbooks_realm_id: params[:realmId],
        quickbooks_sync_enabled: true
      )
      
      # Reload again to confirm update
      entity.reload
      Rails.logger.info "[QB Callback] Token expires at FINAL: #{entity.quickbooks_token_expires_at.inspect}"
      
      # Clear session variables
      session.delete(:qb_oauth_state)
      session.delete(:qb_company_id)
      session.delete(:qb_location_id)
      session.delete(:qb_return_url)
      
      # Return success with entity info and return URL
      render json: { 
        success: true, 
        company_name: company.name,
        location_name: entity.is_a?(Location) ? entity.name : nil,
        scope: entity.is_a?(Location) ? 'location' : 'company',
        realm_id: params[:realmId],
        return_url: return_url # Include return URL for frontend redirect
      }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end
  
  def status
    return unless authorize_action!('settings', 'read')
    
    entity = determine_quickbooks_entity
    
    Rails.logger.info "[QB Status] Entity: #{entity&.class&.name}##{entity&.id}"
    Rails.logger.info "[QB Status] Token expires at: #{entity&.quickbooks_token_expires_at.inspect}"
    Rails.logger.info "[QB Status] Connected at: #{entity&.quickbooks_connected_at.inspect}"
    
    # Fetch company name from QuickBooks (cached for 1 hour to avoid excessive API calls)
    Rails.logger.info "[QB Status] About to fetch company name for entity: #{entity&.class&.name}##{entity&.id}"
    Rails.logger.info "[QB Status] Entity connected? #{entity&.quickbooks_connected?}"
    
    company_name = if entity&.quickbooks_connected?
      cache_key = "qb_company_name_#{entity.class.name}_#{entity.id}"
      Rails.logger.info "[QB Status] Cache key: #{cache_key}"
      
      Rails.cache.fetch(cache_key, expires_in: 1.hour) do
        Rails.logger.info "[QB Status] Cache miss - fetching from QuickBooks"
        name = entity.quickbooks_company_name
        Rails.logger.info "[QB Status] Fetched name: #{name.inspect}"
        name
      end
    else
      Rails.logger.info "[QB Status] Entity not connected, skipping name fetch"
      nil
    end
    
    Rails.logger.info "[QB Status] Final company_name: #{company_name.inspect}"
    
    render json: {
      connected: entity&.quickbooks_connected? || false,
      realm_id: entity&.quickbooks_realm_id,
      company_name: company_name,
      connected_at: entity&.quickbooks_connected_at,
      last_sync_at: entity&.quickbooks_last_sync_at,
      token_expires_at: entity&.quickbooks_token_expires_at,
      sync_enabled: entity&.quickbooks_sync_enabled,
      scope: @company.quickbooks_scope,
      entity_type: entity.is_a?(Location) ? 'location' : 'company',
      entity_name: entity.is_a?(Location) ? entity.name : @company.name
    }
  end
  
  def disconnect
    return unless authorize_action!('settings', 'update')
    
    entity = determine_quickbooks_entity
    return render json: { error: 'Entity not found' }, status: :not_found unless entity
    
    oauth_service = QuickbooksOauthService.new(entity)
    result = oauth_service.revoke_token!
    
    if result[:success]
      render json: { success: true, message: 'Disconnected from QuickBooks' }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end
  
  def refresh_token
    return unless authorize_action!('settings', 'update')
    
    entity = determine_quickbooks_entity
    return render json: { error: 'Entity not found' }, status: :not_found unless entity
    
    result = entity.refresh_quickbooks_token!
    
    if result[:success]
      render json: { success: true, expires_at: result[:expires_at] }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end
  
  private
  
  # Determine which entity (company or location) to use for QuickBooks
  def determine_quickbooks_entity
    if params[:location_id].present?
      # Location-specific request
      @company.locations.find_by(id: params[:location_id])
    elsif @company.quickbooks_scope == 'location'
      # Location scope but no location_id - return nil to force error
      nil
    else
      # Company scope
      @company
    end
  end
end
