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

    connections = UserEmailConnection
                    .joins(:user)
                    .where(users: { company_id: @company.id })
                    .where(is_active: true)

    connections.map do |conn|
      display = conn.display_name.presence ||
                [conn.user&.first_name, conn.user&.last_name].compact.join(' ').presence ||
                conn.email_address
      {
        from_identity_type: 'User',
        from_identity_id: conn.user_id,
        email_address: conn.email_address,
        display_name: display,
        provider: conn.provider,
        is_default: conn.user_id == current_user.id,
        is_current_user: conn.user_id == current_user.id
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
        is_default: false
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
        is_default: false
      }
    end
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
