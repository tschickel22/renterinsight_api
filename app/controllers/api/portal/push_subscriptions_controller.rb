# app/controllers/api/portal/push_subscriptions_controller.rb
#
# Device registration for the customer portal app. Mirrors the staff controller,
# but the owner is the BuyerPortalAccess rather than a User, and there are no
# per-type preferences: the portal only pushes things waiting on the customer.
module Api
  module Portal
    class PushSubscriptionsController < BaseController
      def index
        subscriptions = access_subscriptions.active.order(last_seen_at: :desc)

        render json: {
          subscriptions: subscriptions.map(&:as_json_for_client),
          external_id: PushSubscription.external_id_for(current_buyer_access),
          push_opt_in: current_buyer_access.push_opt_in != false,
          configured: PushNotificationService.configured?('portal')
        }
      end

      def create
        if params[:player_id].blank?
          return render json: { error: 'player_id is required' }, status: :unprocessable_entity
        end

        subscription = PushSubscription.register!(
          owner: current_buyer_access,
          player_id: params[:player_id],
          platform: params[:platform],
          device_model: params[:device_model],
          app_version: params[:app_version],
          natively_version: params[:natively_version],
          permission_granted: permission_granted_param
        )

        # Registering a device is consent. Someone who turned push off and then
        # allowed the OS prompt again would otherwise stay silently opted out.
        current_buyer_access.update_column(:push_opt_in, true) if current_buyer_access.push_opt_in == false

        render json: {
          subscription: subscription.as_json_for_client,
          external_id: subscription.external_id
        }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end

      def destroy
        subscription = access_subscriptions.find_by(player_id: params[:id])

        if subscription.blank?
          return render json: { error: 'Subscription not found' }, status: :not_found
        end

        subscription.revoke!('unregistered_by_user')
        render json: { success: true }
      end

      # The customer's one switch for the whole channel, alongside the existing
      # email_opt_in / sms_opt_in.
      def opt_in
        opted_in = ActiveModel::Type::Boolean.new.cast(params[:push_opt_in]) != false
        current_buyer_access.update!(push_opt_in: opted_in)

        render json: { success: true, push_opt_in: opted_in }
      end

      def test
        result = PushNotificationService.send_test(owner: current_buyer_access, player_id: params[:player_id])

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

      def access_subscriptions
        PushSubscription.where(owner_type: 'BuyerPortalAccess', owner_id: current_buyer_access.id)
      end

      def permission_granted_param
        return true if params[:permission_granted].nil?

        ActiveModel::Type::Boolean.new.cast(params[:permission_granted]) != false
      end
    end
  end
end
