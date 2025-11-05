# frozen_string_literal: true
require "ostruct"

class ApplicationController < ActionController::API
  include ActionController::Cookies
  
  before_action :authenticate

  private

  def authenticate
    # Extract and verify JWT token
    header = request.headers['Authorization']
    
    if header.present?
      token = header.split(' ').last
      
      begin
        decoded = JWT.decode(
          token,
          Rails.application.credentials.jwt_secret || ENV['JWT_SECRET'] || Rails.application.secret_key_base,
          true,
          { algorithm: 'HS256' }
        )[0]
        
        @current_user = User.find_by(id: decoded['user_id'])
        @current_company_id = @current_user&.company_id || decoded['company_id'] || 1
        
        # If user not found or token invalid, log and reject
        unless @current_user
          Rails.logger.warn "[ApplicationController] JWT decode error: User not found for id=#{decoded['user_id']}"
          render json: { error: 'Unauthorized - Invalid or missing token' }, status: :unauthorized
          return
        end
        
      rescue JWT::ExpiredSignature => e
        Rails.logger.info "[ApplicationController] JWT decode error: Signature has expired"
        render json: { error: 'Unauthorized - Token has expired', expired: true }, status: :unauthorized
        return
      rescue JWT::DecodeError => e
        Rails.logger.warn "[ApplicationController] JWT decode error: #{e.message}"
        render json: { error: 'Unauthorized - Invalid or missing token' }, status: :unauthorized
        return
      end
    else
      # No authorization header - use fallback for development/legacy support
      @current_company_id = (request.headers['X-Company-Id'] || 1).to_i
      @current_user ||= User.first # Fallback for development
      
      unless Rails.env.development?
        render json: { error: 'Unauthorized - Missing authorization header' }, status: :unauthorized
        return
      end
    end
  end

  def current_company_id
    @current_company_id
  end

  def current_user
    @current_user ||= User.first # Fallback for development
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

end
