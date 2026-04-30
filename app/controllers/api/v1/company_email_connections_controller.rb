# frozen_string_literal: true

# Singular resource controller for the one-and-only company-level email connection.
# Routes use the singular form `company-email-connection` (no :id segment).

class Api::V1::CompanyEmailConnectionsController < ApplicationController
  before_action :set_company_scope
  before_action :set_connection, only: [:show, :update, :destroy, :test, :send_verification]

  # GET /api/v1/company-email-connection
  def show
    return unless authorize_action!('company_settings', 'update')
    if @connection.nil?
      render json: { connection: nil, message: 'No company-level email connection configured' }
    else
      render json: { connection: connection_json(@connection, include_smtp_details: true) }
    end
  end

  # POST /api/v1/company-email-connection
  def create
    return unless authorize_action!('company_settings', 'update')

    existing = CompanyEmailConnection.find_by(company_id: @company.id)
    if existing
      return render json: { error: 'A company email connection already exists. Update or delete it first.' }, status: :unprocessable_entity
    end

    @connection = CompanyEmailConnection.new(connection_params)
    @connection.company = @company

    if @connection.email_matches_verified_domain?
      @connection.provider = 'company_domain'
      @connection.verified_at = Time.current
    end

    if @connection.save
      if @connection.smtp_provider? && @connection.smtp_credentials_valid?
        @connection.test_smtp_connection!
      end
      render json: {
        connection: connection_json(@connection, include_smtp_details: true),
        message: 'Company email connection created successfully'
      }, status: :created
    else
      render json: { errors: @connection.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/company-email-connection
  def update
    return unless authorize_action!('company_settings', 'update')
    return render(json: { error: 'No company email connection exists' }, status: :not_found) unless @connection

    if params.dig(:connection, :email_address).present? &&
       params[:connection][:email_address] != @connection.email_address &&
       @connection.verified?
      return render json: {
        error: 'Cannot change email address on a verified connection. Please create a new connection.'
      }, status: :unprocessable_entity
    end

    if @connection.update(connection_params)
      if @connection.smtp_provider? &&
         (params.dig(:connection, :smtp_password).present? ||
          params.dig(:connection, :smtp_host).present? ||
          params.dig(:connection, :smtp_username).present?)
        @connection.test_smtp_connection!
      end

      render json: {
        connection: connection_json(@connection, include_smtp_details: true),
        message: 'Company email connection updated successfully'
      }
    else
      render json: { errors: @connection.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/company-email-connection
  def destroy
    return unless authorize_action!('company_settings', 'update')
    return render(json: { error: 'No company email connection exists' }, status: :not_found) unless @connection
    @connection.destroy
    render json: { message: 'Company email connection deleted successfully' }
  end

  # POST /api/v1/company-email-connection/test
  def test
    return unless authorize_action!('company_settings', 'update')
    return render(json: { error: 'No company email connection exists' }, status: :not_found) unless @connection

    unless @connection.smtp_provider?
      return render json: {
        success: false,
        error: 'Only SMTP connections can be tested'
      }, status: :unprocessable_entity
    end

    result = @connection.test_smtp_connection!

    render json: {
      success: result[:success],
      message: result[:success] ? 'Connection successful!' : nil,
      error: result[:error],
      connection: connection_json(@connection.reload)
    }
  end

  # POST /api/v1/company-email-connection/send_verification
  def send_verification
    return unless authorize_action!('company_settings', 'update')
    return render(json: { error: 'No company email connection exists' }, status: :not_found) unless @connection

    if @connection.verified?
      return render json: { error: 'Connection is already verified' }, status: :unprocessable_entity
    end

    if @connection.smtp_provider?
      return render json: {
        error: 'SMTP connections are verified by testing the connection'
      }, status: :unprocessable_entity
    end

    # Company connections do not have generate_verification_token! — keep parity by short-circuiting
    render json: { error: 'Verification flow for company connections must use OAuth or SMTP test' }, status: :unprocessable_entity
  end

  private

  def set_connection
    @connection = CompanyEmailConnection.find_by(company_id: @company.id)
  end

  def connection_params
    params.require(:connection).permit(
      :email_address,
      :display_name,
      :provider,
      :smtp_host,
      :smtp_port,
      :smtp_username,
      :smtp_password,
      :smtp_authentication,
      :smtp_enable_tls,
      :smtp_enable_starttls,
      :is_active
    )
  end

  def connection_json(connection, include_smtp_details: false)
    json = {
      id: connection.id,
      email_address: connection.email_address,
      display_name: connection.display_name,
      provider: connection.provider,
      is_active: connection.is_active,
      verified: connection.verified?,
      verified_at: connection.verified_at,
      requires_verification: connection.requires_verification?,
      last_used_at: connection.last_used_at,
      last_error_at: connection.last_error_at,
      last_error_message: connection.last_error_message,
      created_at: connection.created_at,
      updated_at: connection.updated_at
    }

    if include_smtp_details && connection.smtp_provider?
      json.merge!(
        smtp_host: connection.smtp_host,
        smtp_port: connection.smtp_port,
        smtp_username: connection.smtp_username,
        smtp_authentication: connection.smtp_authentication,
        smtp_enable_tls: connection.smtp_enable_tls,
        smtp_enable_starttls: connection.smtp_enable_starttls,
        smtp_password_set: connection.smtp_password_encrypted.present?
      )
    end

    json
  end
end
