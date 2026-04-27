# frozen_string_literal: true

class Api::V1::LocationEmailConnectionsController < ApplicationController
  before_action :set_company_scope
  before_action :set_connection, only: [:show, :update, :destroy, :test, :set_default, :send_verification]

  # GET /api/v1/location-email-connections
  def index
    return unless authorize_action!('locations', 'update')

    connections = LocationEmailConnection.where(company_id: @company.id).order(created_at: :asc)

    render json: {
      connections: connections.map { |c| connection_json(c) },
      verified_company_domains: @company.verified_email_domains || []
    }
  end

  # GET /api/v1/location-email-connections/:id
  def show
    return unless authorize_action!('locations', 'update')
    render json: { connection: connection_json(@connection, include_smtp_details: true) }
  end

  # POST /api/v1/location-email-connections
  def create
    return unless authorize_action!('locations', 'update')

    location = @company.locations.find_by(id: params.dig(:connection, :location_id) || params[:location_id])
    return render(json: { error: 'location_id is required and must belong to your company' }, status: :unprocessable_entity) unless location

    @connection = LocationEmailConnection.new(connection_params)
    @connection.location = location
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
        message: 'Location email connection created successfully'
      }, status: :created
    else
      render json: { errors: @connection.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/location-email-connections/:id
  def update
    return unless authorize_action!('locations', 'update')

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
        message: 'Location email connection updated successfully'
      }
    else
      render json: { errors: @connection.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/location-email-connections/:id
  def destroy
    return unless authorize_action!('locations', 'update')
    @connection.destroy
    render json: { message: 'Location email connection deleted successfully' }
  end

  # POST /api/v1/location-email-connections/:id/test
  def test
    return unless authorize_action!('locations', 'update')

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

  # POST /api/v1/location-email-connections/:id/set_default
  # No-op for locations (one connection per location, enforced by unique index).
  # Endpoint kept for API symmetry with user_email_connections.
  def set_default
    return unless authorize_action!('locations', 'update')

    unless @connection.verified?
      return render json: { error: 'Only verified connections can be set as default' }, status: :unprocessable_entity
    end

    render json: {
      connection: connection_json(@connection),
      message: 'Location has only one connection — already default'
    }
  end

  # POST /api/v1/location-email-connections/:id/send_verification
  def send_verification
    return unless authorize_action!('locations', 'update')

    if @connection.verified?
      return render json: { error: 'Connection is already verified' }, status: :unprocessable_entity
    end

    if @connection.smtp_provider?
      return render json: {
        error: 'SMTP connections are verified by testing the connection, not email verification'
      }, status: :unprocessable_entity
    end

    token = @connection.generate_verification_token!
    verification_url = "#{ENV['FRONTEND_URL']}/settings/email/verify?token=#{token}"

    CommunicationService.send_email(
      communicable: current_user,
      to: @connection.email_address,
      subject: 'Verify your email address',
      body: <<~HTML
        <p>Please verify that you own this email address by clicking the link below:</p>
        <p><a href="#{verification_url}">Verify Email Address</a></p>
        <p>This link will expire in 24 hours.</p>
      HTML
    )

    render json: {
      message: 'Verification email sent',
      sent_to: @connection.email_address
    }
  end

  private

  def set_connection
    @connection = LocationEmailConnection.where(company_id: @company.id).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Location email connection not found' }, status: :not_found
  end

  def connection_params
    params.require(:connection).permit(
      :location_id,
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
      location_id: connection.location_id,
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
