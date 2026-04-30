class Api::V1::EmailSendersController < ApplicationController
  before_action :set_company_scope

  def index
    return unless authorize_action!('campaigns', 'read')

    render json: {
      user_senders: user_senders,
      location_senders: location_senders,
      company_senders: company_senders,
      sms_senders: sms_senders
    }
  end

  private

  def user_senders
    return [] unless defined?(UserEmailConnection)

    # Strictly scope to connections that belong to the current company.
    # Campaign#resolve_email_connection rejects any connection whose
    # company_id does not match the campaign's, so showing a connection
    # the resolver would refuse is a UX trap (picker succeeds, send
    # silently fails). Platform admins in a tenant context must connect
    # an account in that tenant if they want to send from it.
    connections = UserEmailConnection
                    .where(company_id: @company.id, is_active: true)
                    .includes(:user)

    connections.map do |conn|
      first_name = conn.user&.first_name
      last_name  = conn.user&.last_name
      user_name  = [first_name, last_name].compact.map(&:to_s).map(&:strip).reject(&:empty?).join(' ').presence

      # Treat the connection's display_name as a customization only when it
      # differs from the email_address. The OAuth flow historically stamped
      # display_name = email, which made the picker show emails instead of
      # names; ignore that case so user_name wins.
      custom_display = conn.display_name.presence
      custom_display = nil if custom_display && custom_display.casecmp(conn.email_address.to_s).zero?

      {
        from_identity_type: 'User',
        from_identity_id: conn.user_id,
        email_address: conn.email_address,
        first_name: first_name,
        last_name: last_name,
        user_name: user_name,
        display_name: user_name || custom_display || conn.email_address,
        provider: conn.provider,
        is_default: conn.user_id == current_user.id,
        is_current_user: conn.user_id == current_user.id,
        connection_id: conn.id,
        status: connection_status(conn)
      }
    end
  end

  def location_senders
    return [] unless defined?(LocationEmailConnection)

    connections = LocationEmailConnection
                    .joins(:location)
                    .where(locations: { company_id: @company.id })
                    .where(is_active: true)

    if current_user.uses_rbac? && !current_user.effective_admin?
      accessible = permission_service.accessible_location_ids
      connections = connections.where(location_id: accessible) if accessible.any?
    end

    connections.map do |conn|
      {
        from_identity_type: 'Location',
        from_identity_id: conn.location_id,
        email_address: conn.email_address,
        display_name: conn.display_name.presence || conn.location&.name,
        provider: conn.provider,
        is_default: false,
        connection_id: conn.id,
        status: connection_status(conn)
      }
    end
  end

  def company_senders
    return [] unless defined?(CompanyEmailConnection)

    connections = CompanyEmailConnection
                    .where(company_id: @company.id, is_active: true)

    connections.map do |conn|
      {
        from_identity_type: 'Company',
        from_identity_id: @company.id,
        email_address: conn.email_address,
        display_name: conn.display_name.presence || @company.name,
        provider: conn.provider,
        is_default: false,
        connection_id: conn.id,
        status: connection_status(conn)
      }
    end
  end

  def connection_status(conn)
    return 'needs_reconnect' if conn.oauth_token_encrypted.blank?

    expiry = conn.oauth_expires_at
    return 'healthy' if expiry.nil? || expiry > Time.current

    conn.oauth_refresh_token_encrypted.present? ? 'healthy' : 'needs_reconnect'
  end

  def sms_senders
    return [] unless defined?(TwilioAccount)

    accounts = @company.twilio_accounts.active

    accounts.map do |acct|
      {
        from_identity_type: 'Company',
        from_identity_id: @company.id,
        phone_number: acct.phone_number,
        display_name: @company.name,
        is_default: false
      }
    end
  end
end
