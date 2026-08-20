# frozen_string_literal: true

# Biometric unlock: the credential a phone stores behind Face ID.
#
# #create is the enrolment step and requires a normal, fully authenticated
# session, so the first time someone turns this on they have already passed the
# password and whatever MFA their company enforces. #exchange is what every
# later launch calls, and is deliberately the only unauthenticated action here:
# possession of the token IS the credential, and the device only surrenders it
# after a successful biometric check.
class Api::V1::DeviceSessionsController < ApplicationController
  skip_before_action :authenticate, only: [:exchange]
  skip_before_action :set_company_scope, only: [:exchange], raise: false

  # GET /api/v1/device-sessions
  # The "phones that can unlock without a password" list in settings.
  def index
    sessions = DeviceSession.active.where(user_id: current_user.id).order(last_used_at: :desc, created_at: :desc)

    render json: { device_sessions: sessions.map(&:as_json_for_client) }
  end

  # POST /api/v1/device-sessions
  # Enrol this device. Returns the raw token exactly once.
  def create
    session, raw_token = DeviceSession.issue!(
      user: current_user,
      device_label: params[:device_label],
      platform: params[:platform],
      app_version: params[:app_version],
      player_id: params[:player_id]
    )

    render json: {
      success: true,
      device_token: raw_token,
      device_session: session.as_json_for_client
    }, status: :created
  rescue StandardError => e
    Rails.logger.error("[DeviceSession] Could not enrol user #{current_user&.id}: #{e.message}")
    render json: { success: false, message: 'Could not enable biometric unlock' },
           status: :unprocessable_entity
  end

  # POST /api/v1/device-sessions/exchange
  # Trade the stored token for a normal session.
  def exchange
    session = DeviceSession.authenticate(params[:device_token])

    # One message for every failure. Distinguishing "expired" from "unknown"
    # tells an attacker with a stolen phone which tokens were ever real.
    return render_exchange_failure if session.blank?

    user = session.user
    if user.blank? || user.inactive? || user.suspended?
      session.revoke!('account_inactive')
      return render_exchange_failure
    end

    session.touch_use!
    user.update_columns(last_sign_in_at: Time.current, updated_at: Time.current)

    LoginActivity.record_login(
      user_id: user.id,
      user_type: 'User',
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )

    tokens = JsonWebToken.generate_token_pair(user)

    render json: {
      success: true,
      token: tokens[:access_token],
      refreshToken: tokens[:refresh_token],
      user: { id: user.id, email: user.email, first_name: user.first_name, last_name: user.last_name,
              role: user.role, company_id: user.company_id }
    }, status: :ok
  rescue StandardError => e
    Rails.logger.error("[DeviceSession] Exchange failed: #{e.message}")
    render_exchange_failure
  end

  # DELETE /api/v1/device-sessions/:id
  # Turning the toggle off, or dropping a phone from the list.
  def destroy
    session = DeviceSession.where(user_id: current_user.id).find_by(id: params[:id])
    return render(json: { error: 'Not found' }, status: :not_found) if session.blank?

    session.revoke!('user_removed')
    render json: { success: true }
  end

  # DELETE /api/v1/device-sessions
  # "Sign out of all phones".
  def destroy_all
    DeviceSession.revoke_all_for(current_user, 'user_removed_all')
    render json: { success: true }
  end

  private

  def render_exchange_failure
    render json: {
      success: false,
      message: 'Biometric unlock is no longer valid. Please sign in with your password.'
    }, status: :unauthorized
  end
end
