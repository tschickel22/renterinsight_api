# frozen_string_literal: true

class Api::Platform::TwilioProvisioningController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_company

  # POST /api/platform/tenants/:tenant_id/twilio/provision
  def provision
    area_code = params[:area_code].presence
    country   = params[:country].presence || 'US'
    result = TwilioProvisioningService.provision_client(@company, area_code: area_code, country: country)

    if result[:success]
      render json: {
        message: 'SMS provisioning successful',
        phone_number: result[:phone_number],
        sub_account_sid: result[:sub_account_sid],
        status: 'active'
      }, status: :created
    else
      render json: {
        error: result[:error],
        error_code: result[:error_code],
        area_code: result[:area_code]
      }, status: :unprocessable_entity
    end
  end

  # DELETE /api/platform/tenants/:tenant_id/twilio/deprovision
  def deprovision
    result = TwilioProvisioningService.deprovision_client(@company)

    if result[:success]
      render json: { message: 'SMS deprovisioned successfully, reverted to platform mode' }
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  end

  # GET /api/platform/tenants/:tenant_id/twilio/status
  def status
    twilio_account = @company.twilio_account

    if twilio_account
      render json: {
        provisioned: true,
        status: twilio_account.status,
        phone_number: twilio_account.phone_number,
        sub_account_sid: twilio_account.sub_account_sid,
        provisioned_at: twilio_account.provisioned_at,
        sms_provisioning_mode: @company.sms_provisioning_mode,
        metadata: twilio_account.metadata
      }
    else
      render json: {
        provisioned: false,
        status: nil,
        phone_number: nil,
        sms_provisioning_mode: @company.sms_provisioning_mode
      }
    end
  end

  private

  def set_company
    @company = Company.find(params[:tenant_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Company not found' }, status: :not_found
  end
end
