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
# Routes:
#   POST /webhooks/zego/processed
#   POST /webhooks/zego/canceled

class Webhooks::ZegoController < ApplicationController
  # Skip authentication - webhooks come from external service
  skip_before_action :authenticate
  skip_before_action :set_current_attributes
  
  # Processed payment webhook
  # Called when Zego successfully processes a payment
  def processed
    log_webhook('processed', params)
    
    # Enqueue async job to process the webhook
    HandlePaymentUpdateJob.perform_later('processed', params.permit!.to_json)
    
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
    HandlePaymentUpdateJob.perform_later('canceled', params.permit!.to_json)
    
    # Return 200 OK immediately to Zego
    render plain: 'OK', status: :ok
  rescue => e
    # Log error but still return OK to prevent Zego retries
    Rails.logger.error("Zego canceled webhook error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    
    render plain: 'OK', status: :ok
  end
  
  private
  
  # Log webhook details for debugging
  def log_webhook(status, params)
    Rails.logger.info("=" * 80)
    Rails.logger.info("Zego Webhook: #{status.upcase}")
    Rails.logger.info("Timestamp: #{Time.current}")
    Rails.logger.info("IP Address: #{request.remote_ip}")
    Rails.logger.info("Params: #{params.to_json}")
    Rails.logger.info("=" * 80)
  end
end
