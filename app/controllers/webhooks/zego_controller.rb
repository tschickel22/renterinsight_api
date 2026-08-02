# frozen_string_literal: true

# Webhooks::ZegoController
#
# Handles webhook callbacks from Zego payment gateway for payment status updates.
# Zego sends callbacks for:
#   - processed: Payment successfully processed
#   - canceled: Payment was canceled or failed
#
# All webhook processing is handled asynchronously via HandlePaymentUpdateJob
# to ensure quick response to Zego and prevent timeout issues.
#
# AUTHENTICATION
#
# These endpoints reach HandlePaymentUpdateJob, which does payment.update!(status:
# 'completed') keyed on payment_reference_id taken straight from the request body. Left
# open, that is an unauthenticated write marking arbitrary payments as paid.
#
# Zego does not sign its callbacks, so there is no signature to verify. Instead the
# callback URL registered with Zego must carry a shared secret, checked here in constant
# time:
#
#   https://api.example.com/webhooks/zego/processed?token=<ZEGO_WEBHOOK_TOKEN>
#
# This FAILS CLOSED. With ZEGO_WEBHOOK_TOKEN unset every request is rejected, which is the
# correct state while no tenant is live on Zego. Setting the env var and registering the
# matching callback URL is part of onboarding the first Zego client.
#
# Routes:
#   POST /webhooks/zego/processed
#   POST /webhooks/zego/canceled

class Webhooks::ZegoController < ApplicationController
  # Skip authentication - webhooks come from external service
  skip_before_action :authenticate
  skip_before_action :set_current_attributes
  before_action :authenticate_zego_callback!

  # Processed payment webhook
  # Called when Zego successfully processes a payment
  def processed
    log_webhook('processed', params)
    
    # Enqueue async job to process the webhook
    # except(:token) so the shared secret is not persisted in the job queue or echoed by
    # the job's own error logging.
    HandlePaymentUpdateJob.perform_later('processed', params.except(:token).permit!.to_json)
    
    # Return 200 OK immediately to Zego
    render plain: 'OK', status: :ok
  rescue => e
    # Log error but still return OK to prevent Zego retries
    Rails.logger.error("Zego processed webhook error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    
    render plain: 'OK', status: :ok
  end
  
  # Canceled payment webhook
  # Called when Zego cancels or rejects a payment
  def canceled
    log_webhook('canceled', params)
    
    # Enqueue async job to process the webhook
    HandlePaymentUpdateJob.perform_later('canceled', params.except(:token).permit!.to_json)
    
    # Return 200 OK immediately to Zego
    render plain: 'OK', status: :ok
  rescue => e
    # Log error but still return OK to prevent Zego retries
    Rails.logger.error("Zego canceled webhook error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    
    render plain: 'OK', status: :ok
  end
  
  private

  def authenticate_zego_callback!
    expected = ENV['ZEGO_WEBHOOK_TOKEN'].to_s
    provided = (params[:token] || request.headers['X-Zego-Token']).to_s

    # Unset secret means no Zego tenant is live, so nothing legitimate can be calling.
    if expected.blank?
      Rails.logger.warn("[Zego] rejected callback from #{request.remote_ip}: ZEGO_WEBHOOK_TOKEN not configured")
      return render plain: 'Unauthorized', status: :unauthorized
    end

    return if ActiveSupport::SecurityUtils.secure_compare(expected, provided)

    Rails.logger.warn("[Zego] rejected callback from #{request.remote_ip}: bad token")
    render plain: 'Unauthorized', status: :unauthorized
  end

  # Log webhook details for debugging
  def log_webhook(status, params)
    Rails.logger.info("=" * 80)
    Rails.logger.info("Zego Webhook: #{status.upcase}")
    Rails.logger.info("Timestamp: #{Time.current}")
    Rails.logger.info("IP Address: #{request.remote_ip}")
    # Drop the shared secret before logging: it authenticates the caller, so logging it
    # would hand anyone with log access the ability to forge payment callbacks.
    Rails.logger.info("Params: #{params.except(:token).to_json}")
    Rails.logger.info("=" * 80)
  end
end
