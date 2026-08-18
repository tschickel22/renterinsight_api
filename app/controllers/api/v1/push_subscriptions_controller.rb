# app/controllers/api/v1/push_subscriptions_controller.rb
#
# Device registration for the staff DMS app. The Natively shell hands the web
# app a OneSignal player id on launch; the app posts it here so the server can
# target the device.
#
# No RBAC resource: a user is only ever registering their own phone, and every
# query below is already scoped to current_user.
class Api::V1::PushSubscriptionsController < ApplicationController
  before_action :set_company_scope

  def index
    subscriptions = current_user_subscriptions.active.order(last_seen_at: :desc)

    render json: {
      subscriptions: subscriptions.map(&:as_json_for_client),
      external_id: PushSubscription.external_id_for(current_user),
      configured: PushNotificationService.configured?('staff')
    }
  end

  # Called on every app launch, so it upserts rather than erroring on a repeat.
  def create
    if params[:player_id].blank?
      return render json: { error: 'player_id is required' }, status: :unprocessable_entity
    end

    subscription = PushSubscription.register!(
      owner: current_user,
      player_id: params[:player_id],
      platform: params[:platform],
      device_model: params[:device_model],
      app_version: params[:app_version],
      natively_version: params[:natively_version],
      permission_granted: permission_granted_param
    )

    render json: {
      subscription: subscription.as_json_for_client,
      external_id: subscription.external_id
    }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
  end

  # Logout, or the user switching push off in the app. Scoped to current_user so
  # a guessed player id cannot unsubscribe somebody else's phone.
  def destroy
    subscription = current_user_subscriptions.find_by(player_id: params[:id])

    if subscription.blank?
      return render json: { error: 'Subscription not found' }, status: :not_found
    end

    subscription.revoke!('unregistered_by_user')
    render json: { success: true }
  end

  # "Send a test notification" from the app's notification settings screen.
  def test
    result = PushNotificationService.send_test(owner: current_user, player_id: params[:player_id])

    if result[:success]
      render json: { success: true, recipients: result[:recipients] }
    else
      render json: { success: false, error: result[:error] || 'No registered devices' },
             status: :unprocessable_entity
    end
  rescue Providers::Push::OneSignalProvider::ConfigurationError => e
    render json: { success: false, error: e.message }, status: :service_unavailable
  rescue Providers::Push::OneSignalProvider::DeliveryError => e
    render json: { success: false, error: e.message }, status: :bad_gateway
  end

  private

  def current_user_subscriptions
    PushSubscription.where(owner_type: 'User', owner_id: current_user.id)
  end

  def permission_granted_param
    return true if params[:permission_granted].nil?

    ActiveModel::Type::Boolean.new.cast(params[:permission_granted]) != false
  end
end
