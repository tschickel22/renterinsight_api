# frozen_string_literal: true
require "ostruct"

class ApplicationController < ActionController::API
  include ActionController::Cookies
  
  before_action :authenticate

  private

  def authenticate
    # Extract token from Authorization header
    header = request.headers['Authorization']
    
    if header.present?
      token = header.split(' ').last
      decoded = JsonWebToken.decode(token)
      
      if decoded
        # Valid JWT token found
        @current_user_id = decoded[:user_id]
        @current_company_id = decoded[:company_id] || request.headers['X-Company-Id']&.to_i || 1
        return
      else
        # Token decode failed (expired or invalid)
        Rails.logger.warn "[ApplicationController] JWT decode failed for token"
        render json: { error: 'Unauthorized - Invalid or expired token' }, status: :unauthorized
        return
      end
    end
    
    # No valid token - return unauthorized
    Rails.logger.warn "[ApplicationController] No authorization header present"
    render json: { error: 'Unauthorized - Missing authorization header' }, status: :unauthorized
  end

  def current_company_id
    # For tenant/super_admin users, allow override via X-Company-ID header (platform admin switching)
    if current_user&.role.in?(['tenant', 'super_admin', 'admin'])
      # Try both X-Company-ID and X-Company-Context for backward compatibility
      context_company_id = request.headers['X-Company-ID']&.to_i || request.headers['X-Company-Context']&.to_i
      return context_company_id if context_company_id.present? && context_company_id > 0
    end
    
    # Otherwise use the company from JWT token
    @current_company_id
  end

  def current_user
    return @current_user if defined?(@current_user)
    
    # Load user from JWT token
    if @current_user_id
      @current_user = User.find_by(id: @current_user_id)
      
      unless @current_user
        Rails.logger.error("JWT token contains invalid user_id: #{@current_user_id}")
        render json: { error: 'Unauthorized - User not found' }, status: :unauthorized
        return nil
      end
      
      return @current_user
    end
    
    # No authenticated user
    nil
  end
  
  # Portal authentication helpers
  def current_portal_buyer
    return @current_portal_buyer if @current_portal_buyer
    
    header = request.headers['Authorization']
    return nil unless header.present?
    
    token = header.split(' ').last
    decoded = JsonWebToken.decode(token)
    return nil unless decoded
    
    # Support both unified auth (user_id) and portal auth (buyer_portal_access_id)
    if decoded[:buyer_portal_access_id]
      # Old portal auth token
      @current_portal_buyer = BuyerPortalAccess.find_by(id: decoded[:buyer_portal_access_id])
    elsif decoded[:user_id] && decoded[:email]
      # Unified auth token - find BuyerPortalAccess by email
      @current_portal_buyer = BuyerPortalAccess.find_by(email: decoded[:email])
    end
    
    @current_portal_buyer
  rescue
    nil
  end

  def authenticate_portal_buyer!
    unless current_portal_buyer
      render json: { error: 'Unauthorized' }, status: :unauthorized
    end
  end

  def authorize_buyer_resource!(resource)
    unless current_portal_buyer.buyer == resource.buyer
      render json: { error: 'Forbidden' }, status: :forbidden
    end
  end

  # Location-based authorization helpers
  def current_user_locations
    return [] unless current_user
    return @current_user_locations if defined?(@current_user_locations)
    
    # Company admins have access to all locations
    if current_user.admin?
      @current_user_locations = current_company.locations.where(is_deleted: false, active: true)
    else
      # Regular users only access their assigned locations
      @current_user_locations = current_user.locations
                                           .where(is_deleted: false, active: true)
                                           .where(user_locations: { active: true })
    end
    
    @current_user_locations
  end
  
  def can_access_location?(location)
    return false unless current_user && location
    
    # Company admins can access all locations
    return true if current_user.admin?
    
    # Check if user has an active assignment to this location
    current_user_locations.exists?(id: location.id)
  end
  
  def location_admin?(location)
    return false unless current_user && location
    
    # Company admins have admin rights everywhere
    return true if current_user.admin?
    
    # Check if user is a location admin for this specific location
    UserLocation.exists?(
      user_id: current_user.id,
      location_id: location.id,
      location_role: 'location_admin',
      active: true
    )
  end
  
  def can_manage_location?(location)
    return false unless current_user && location
    
    # Company admins can manage all locations
    return true if current_user.admin?
    
    # Location admins and managers can manage operations
    user_location = UserLocation.find_by(
      user_id: current_user.id,
      location_id: location.id,
      active: true
    )
    
    user_location&.location_role&.in?(['location_admin', 'location_manager'])
  end
  
  def current_company
    return @current_company if defined?(@current_company)
    @current_company = ::Company.find_by(id: current_company_id)
  end

end
