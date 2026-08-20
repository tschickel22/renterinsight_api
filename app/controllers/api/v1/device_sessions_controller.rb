# frozen_string_literal: true

# Biometric unlock for staff, plus the one exchange endpoint every audience
# uses.
#
# Enrolment requires a normal, fully authenticated session, so the first time
# someone turns this on they have already passed the password and whatever MFA
# their company enforces. #exchange is the only unauthenticated action:
# possession of the token IS the credential, and the device only surrenders it
# after a successful biometric check.
class Api::V1::DeviceSessionsController < ApplicationController
  include DeviceSessionEnrollment

  skip_before_action :authenticate, only: [:exchange]
  skip_before_action :set_company_scope, only: [:exchange], raise: false

  # POST /api/v1/device-sessions/exchange
  #
  # Serves staff, customers and contractors from one place: a token identifies
  # its owner, so routing this per audience would only add three ways for the
  # answer to differ.
  def exchange
    session = DeviceSession.authenticate(params[:device_token])

    # One message for every failure. Distinguishing "expired" from "unknown"
    # tells an attacker with a stolen phone which tokens were ever real.
    return render_exchange_failure if session.blank?

    unless session.owner_usable?
      session.revoke!('owner_unusable')
      return render_exchange_failure
    end

    session.touch_use!
    payload = session_payload_for(session.owner)
    return render_exchange_failure if payload.blank?

    # `audience` rather than owner_type: the phone needs to know which app it
    # just unlocked, and 'Vendor' would mean nothing to it.
    render json: payload.merge(success: true, audience: session.audience), status: :ok
  rescue StandardError => e
    Rails.logger.error("[DeviceSession] Exchange failed: #{e.message}")
    render_exchange_failure
  end

  private

  def device_session_owner
    current_user
  end

  # Each audience carries a different kind of session, so unlocking has to mint
  # the same thing its own login screen would have.
  def session_payload_for(owner)
    case owner
    when ::User              then staff_payload(owner)
    when ::BuyerPortalAccess then portal_payload(owner)
    when ::Vendor            then contractor_payload(owner)
    end
  end

  def staff_payload(user)
    user.update_columns(last_sign_in_at: Time.current, updated_at: Time.current)
    LoginActivity.record_login(
      user_id: user.id, user_type: 'User',
      ip_address: request.remote_ip, user_agent: request.user_agent
    )

    tokens = JsonWebToken.generate_token_pair(user)
    {
      token: tokens[:access_token],
      refreshToken: tokens[:refresh_token],
      user: { id: user.id, email: user.email, first_name: user.first_name,
              last_name: user.last_name, role: user.role, company_id: user.company_id }
    }
  end

  def portal_payload(access)
    access.record_login!(request.remote_ip) if access.respond_to?(:record_login!)

    {
      token: JsonWebToken.encode(buyer_portal_access_id: access.id),
      buyer: {
        id: access.buyer_id,
        email: access.email,
        name: access.buyer.try(:full_name),
        company_id: access.company_id,
        user_type: 'buyer'
      }
    }
  end

  def contractor_payload(vendor)
    # owner_usable? has already established this vendor is an active
    # contractor; reload through Contractor so the token generator sees the
    # class its own login screen would have handed it.
    contractor = ::Contractor.find_by(id: vendor.id)
    return nil if contractor.blank?

    contractor.update_columns(last_portal_login_at: Time.current, updated_at: Time.current)

    {
      token: Api::Contractor::BaseController.generate_contractor_token(contractor),
      contractor: {
        id: contractor.id,
        email: contractor.email,
        name: contractor.try(:name),
        first_name: contractor.try(:first_name),
        last_name: contractor.try(:last_name),
        status: contractor.status
      }
    }
  end

  def render_exchange_failure
    render json: {
      success: false,
      message: 'Biometric unlock is no longer valid. Please sign in with your password.'
    }, status: :unauthorized
  end
end
