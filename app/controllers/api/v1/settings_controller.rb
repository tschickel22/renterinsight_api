class Api::V1::SettingsController < ApplicationController
  before_action :set_company_scope

  # PATCH /api/v1/settings/company
  def company
    return unless authorize_action!('company_settings', 'update')

    update_params = {}
    
    # Handle public inventory enabled toggle
    if params.key?(:public_inventory_enabled)
      update_params[:public_inventory_enabled] = params[:public_inventory_enabled]
      
      # Auto-generate token if enabling and no token exists
      if params[:public_inventory_enabled] && @company.public_inventory_token.blank?
        update_params[:public_inventory_token] = SecureRandom.urlsafe_base64(32)
      end
    end
    
    if @company.update(update_params)
      render json: { 
        success: true,
        company: {
          id: @company.id,
          public_inventory_enabled: @company.public_inventory_enabled,
          public_inventory_token: @company.public_inventory_token
        }
      }
    else
      render json: { 
        errors: @company.errors.full_messages 
      }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/settings/regenerate_public_inventory_token
  def regenerate_public_inventory_token
    return unless authorize_action!('company_settings', 'update')

    new_token = SecureRandom.urlsafe_base64(32)
    
    if @company.update(public_inventory_token: new_token)
      render json: { 
        success: true,
        token: new_token,
        message: 'Token regenerated successfully'
      }
    else
      render json: { 
        errors: @company.errors.full_messages 
      }, status: :unprocessable_entity
    end
  end
end
