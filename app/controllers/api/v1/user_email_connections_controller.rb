# frozen_string_literal: true

class Api::V1::UserEmailConnectionsController < ApplicationController
  before_action :set_company_scope
  before_action :set_connection, only: [:show, :update, :destroy, :test, :set_default, :send_verification, :verify]

  # GET /api/v1/user_email_connections
  # List all email connections for the current user
  def index
    connections = current_user.user_email_connections.order(is_default: :desc, created_at: :asc)
    
    render json: {
      connections: connections.map { |c| connection_json(c) },
      bcc_capture_address: current_user.bcc_capture_address,
      verified_company_domains: @company.verified_email_domains || []
    }
  end

  # GET /api/v1/user_email_connections/:id
  def show
    render json: { connection: connection_json(@connection, include_smtp_details: true) }
  end

  # POST /api/v1/user_email_connections
  # Create a new email connection
  def create
    @connection = current_user.user_email_connections.build(connection_params)
    @connection.company = @company
    
    # A company-domain address needs no proof of ownership, so auto-verify it.
    # Don't let that override an explicit SMTP setup, though: rewriting the
    # provider stored the user's host, username, and password and then never
    # used them (smtp_provider? goes false, so to_smtp_settings returns nil) —
    # their mail quietly went out through the company sender instead.
    if @connection.email_matches_verified_domain?
      @connection.provider = 'company_domain' unless @connection.smtp_provider?
      @connection.verified_at = Time.current
    end
    
    if @connection.save
      # For SMTP connections, test the connection automatically
      if @connection.smtp_provider? && @connection.smtp_credentials_valid?
        test_result = @connection.test_smtp_connection!
        unless test_result[:success]
          Rails.logger.warn "[UserEmailConnection] SMTP test failed on create: #{test_result[:error]}"
        end
      end
      
      render json: { 
        connection: connection_json(@connection, include_smtp_details: true),
        message: 'Email connection created successfully'
      }, status: :created
    else
      render json: { errors: @connection.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/user_email_connections/:id
  def update
    # Don't allow changing the email address if verified (would require re-verification)
    if params.dig(:connection, :email_address).present? && 
       params[:connection][:email_address] != @connection.email_address &&
       @connection.verified?
      return render json: { 
        error: 'Cannot change email address on a verified connection. Please create a new connection.' 
      }, status: :unprocessable_entity
    end
    
    if @connection.update(connection_params)
      # Re-test SMTP if credentials changed
      if @connection.smtp_provider? && 
         (params.dig(:connection, :smtp_password).present? || 
          params.dig(:connection, :smtp_host).present? ||
          params.dig(:connection, :smtp_username).present?)
        test_result = @connection.test_smtp_connection!
      end
      
      render json: { 
        connection: connection_json(@connection, include_smtp_details: true),
        message: 'Email connection updated successfully'
      }
    else
      render json: { errors: @connection.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/user_email_connections/:id
  def destroy
    @connection.destroy
    render json: { message: 'Email connection deleted successfully' }
  end

  # POST /api/v1/user_email_connections/:id/test
  # Test SMTP connection
  def test
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

  # POST /api/v1/user_email_connections/:id/set_default
  # Set this connection as the default
  def set_default
    unless @connection.verified?
      return render json: { 
        error: 'Only verified connections can be set as default' 
      }, status: :unprocessable_entity
    end
    
    @connection.update!(is_default: true)
    
    render json: {
      connection: connection_json(@connection),
      message: 'Default email connection updated'
    }
  end

  # POST /api/v1/user_email_connections/:id/send_verification
  # Send verification email (for non-SMTP connections that need it)
  def send_verification
    if @connection.verified?
      return render json: { error: 'Connection is already verified' }, status: :unprocessable_entity
    end
    
    if @connection.smtp_provider?
      return render json: { 
        error: 'SMTP connections are verified by testing the connection, not email verification' 
      }, status: :unprocessable_entity
    end
    
    # Generate token and send verification email
    token = @connection.generate_verification_token!
    
    # Send verification email via platform email
    # The verification link will include the token
    verification_url = "#{ENV['FRONTEND_URL']}/settings/email/verify?token=#{token}"
    
    CommunicationService.send_email(
      communicable: current_user,
      to: @connection.email_address,
      subject: 'Verify your email address',
      body: <<~HTML
        <p>Please verify that you own this email address by clicking the link below:</p>
        <p><a href="#{verification_url}">Verify Email Address</a></p>
        <p>This link will expire in 24 hours.</p>
        <p>If you did not request this verification, please ignore this email.</p>
      HTML
    )
    
    render json: { 
      message: 'Verification email sent',
      sent_to: @connection.email_address
    }
  end

  # POST /api/v1/user_email_connections/verify
  # Verify email with token (no auth required for this specific action)
  def verify
    token = params[:token]
    
    if token.blank?
      return render json: { error: 'Verification token is required' }, status: :bad_request
    end
    
    connection = UserEmailConnection.find_by(verification_token: token)
    
    if connection.nil?
      return render json: { error: 'Invalid verification token' }, status: :not_found
    end
    
    if connection.verify_with_token!(token)
      render json: { 
        message: 'Email verified successfully',
        connection: connection_json(connection)
      }
    else
      render json: { error: 'Verification token expired or invalid' }, status: :unprocessable_entity
    end
  end

  # GET /api/v1/user_email_connections/check_domain
  # Check if an email domain is verified for the company
  def check_domain
    email = params[:email]
    
    if email.blank?
      return render json: { error: 'Email is required' }, status: :bad_request
    end
    
    domain = email.split('@').last&.downcase
    verified_domains = @company.verified_email_domains || []
    is_verified = verified_domains.map(&:downcase).include?(domain)
    
    render json: {
      email: email,
      domain: domain,
      is_verified_domain: is_verified,
      requires_smtp_or_verification: !is_verified
    }
  end

  private

  def set_connection
    @connection = current_user.user_email_connections.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Email connection not found' }, status: :not_found
  end

  def connection_params
    permitted = params.require(:connection).permit(
      :email_address,
      :display_name,
      :provider,
      :smtp_host,
      :smtp_port,
      :smtp_username,
      :smtp_password,  # Will be encrypted by model
      :smtp_authentication,
      :smtp_enable_tls,
      :smtp_enable_starttls,
      :is_default,
      :is_active
    )

    # The edit form can't pre-fill the stored password (we never return it), so
    # it posts an empty field on every save. Blank means "unchanged" — assigning
    # it through wiped smtp_password_encrypted, and since the presence check only
    # runs on create, renaming a connection silently broke its SMTP sending.
    permitted.delete(:smtp_password) if permitted.key?(:smtp_password) && permitted[:smtp_password].blank?

    permitted
  end

  def connection_json(connection, include_smtp_details: false)
    json = {
      id: connection.id,
      email_address: connection.email_address,
      display_name: connection.display_name,
      provider: connection.provider,
      is_default: connection.is_default,
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
        # Never return the actual password
        smtp_password_set: connection.smtp_password_encrypted.present?
      )
    end
    
    json
  end
end
