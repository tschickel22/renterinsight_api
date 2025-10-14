# frozen_string_literal: true
require "ostruct"

class ApplicationController < ActionController::API
  before_action :authenticate

  private

  def authenticate
    @current_company_id = (request.headers['X-Company-Id'] || 1).to_i
  end

  def current_company_id
    @current_company_id
  end

  def current_user
    # Temporary implementation until you add user authentication
    # Returns a simple object with id and company association
    @current_user ||= OpenStruct.new(id: 1, company_id: current_company_id)
  end
  # Portal authentication helpers
  def current_portal_buyer
    return @current_portal_buyer if @current_portal_buyer
    
    header = request.headers['Authorization']
    return nil unless header.present?
    
    token = header.split(' ').last
    decoded = JsonWebToken.decode(token)
    
    @current_portal_buyer = BuyerPortalAccess.find_by(id: decoded[:buyer_portal_access_id]) if decoded
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
