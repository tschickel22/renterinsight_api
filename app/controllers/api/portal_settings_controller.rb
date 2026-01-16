# frozen_string_literal: true

class Api::PortalSettingsController < ApplicationController
  before_action :set_company_scope

  # GET /api/portal_settings
  def show
    return unless authorize_action!('settings', 'read')
    
    # Get portal settings from Settings table
    portal_settings = Setting.get('Company', @company.id, 'portal') || default_portal_settings
    
    render json: {
      success: true,
      settings: portal_settings
    }
  end

  # PUT /api/portal_settings
  def update
    return unless authorize_action!('settings', 'update')
    
    settings_params = params.require(:settings).permit(
      :dashboard,
      :loanManagement,
      :invoices,
      :quotes,
      :documents,
      :agreementSigning,
      :financeApplications,
      :serviceRequests,
      :settings
    )
    
    # Save to Settings table
    Setting.set('Company', @company.id, 'portal', settings_params.to_h)
    
    render json: {
      success: true,
      message: 'Portal settings updated successfully',
      settings: settings_params.to_h
    }
  rescue => e
    Rails.logger.error "Failed to update portal settings: #{e.message}"
    render json: {
      success: false,
      error: 'Failed to update portal settings'
    }, status: :unprocessable_entity
  end

  private

  def default_portal_settings
    {
      dashboard: true,
      loanManagement: true,
      invoices: true,
      quotes: true,
      documents: true,
      agreementSigning: true,
      financeApplications: true,
      serviceRequests: false,
      settings: true
    }
  end
end
