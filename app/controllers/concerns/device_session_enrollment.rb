# frozen_string_literal: true

# Enrolment and management of biometric-unlock sessions, shared by the staff,
# customer portal and contractor controllers.
#
# The three differ only in who is signed in, which is why each including
# controller supplies `device_session_owner` and nothing else. Exchange is
# deliberately NOT here: it is unauthenticated by nature and lives in one place
# so a token is resolved the same way whoever owns it.
module DeviceSessionEnrollment
  extend ActiveSupport::Concern

  # GET .../device-sessions
  # The "phones that can unlock without a password" list.
  def index
    sessions = DeviceSession.for_owner(device_session_owner).active
                            .order(last_used_at: :desc, created_at: :desc)

    render json: { device_sessions: sessions.map(&:as_json_for_client) }
  end

  # POST .../device-sessions
  # Returns the raw token exactly once.
  def create
    session, raw_token = DeviceSession.issue!(
      owner: device_session_owner,
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
    Rails.logger.error("[DeviceSession] Could not enrol #{device_session_owner.class.name} " \
                       "#{device_session_owner&.id}: #{e.message}")
    render json: { success: false, message: 'Could not enable biometric unlock' },
           status: :unprocessable_entity
  end

  # DELETE .../device-sessions/:id
  def destroy
    session = DeviceSession.for_owner(device_session_owner).find_by(id: params[:id])
    return render(json: { error: 'Not found' }, status: :not_found) if session.blank?

    session.revoke!('user_removed')
    render json: { success: true }
  end

  # DELETE .../device-sessions
  def destroy_all
    DeviceSession.revoke_all_for(device_session_owner, 'user_removed_all')
    render json: { success: true }
  end

  private

  # Each controller answers this with whoever its auth layer signed in.
  def device_session_owner
    raise NotImplementedError, "#{self.class.name} must define device_session_owner"
  end
end
