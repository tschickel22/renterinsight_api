# frozen_string_literal: true

# HandlePaymentUpdateJob
#
# Background job to process Zego payment webhook updates asynchronously.
# Handles both successful (processed) and failed (canceled) payment updates.
#
# Updates payment records based on Zego's response:
#   - Updates payment status
#   - Records transaction IDs and gateway information
#   - Handles ACH returns and cancellations
#   - Logs all updates for audit trail
#
# Usage:
#   HandlePaymentUpdateJob.perform_later('processed', webhook_json)
#   HandlePaymentUpdateJob.perform_later('canceled', webhook_json)

class HandlePaymentUpdateJob < ApplicationJob
  queue_as :default
  
  # Process payment update from Zego webhook
  #
  # @param status [String] 'processed' or 'canceled'
  # @param webhook_data [String] JSON string of webhook parameters
  def perform(status, webhook_data)
    data = JSON.parse(webhook_data)
    
    Rails.logger.info("Processing Zego #{status} webhook for payment #{data['payment_reference_id']}")
    
    case status.to_s
    when 'processed'
      process_successful_payment(data)
    when 'canceled'
      process_canceled_payment(data)
    else
      Rails.logger.error("Unknown webhook status: #{status}")
    end
    
  rescue JSON::ParserError => e
    Rails.logger.error("Failed to parse webhook JSON: #{e.message}")
    Rails.logger.error("Webhook data: #{webhook_data}")
  rescue => e
    Rails.logger.error("Error processing payment update: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    Rails.logger.error("Webhook data: #{webhook_data}")
    
    # Re-raise to trigger retry mechanism
    raise e
  end
  
  private
  
  # Process successful payment webhook
  def process_successful_payment(data)
    payment = find_payment(data)
    return unless payment
    
    # Extract transaction details from webhook
    transaction_id = data['transaction_id'] || data['TransactionId']
    gateway_payer_id = data['gateway_payer_id'] || data['GatewayPayerId']
    amount = data['amount'] || data['Amount']
    
    # Update payment record
    payment.update!(
      status: 'completed',
      external_id: transaction_id,
      processed_at: Time.current,
      gateway_response: data.to_json
    )
    
    # Update payment method's gateway ID if present
    if gateway_payer_id.present? && payment.payment_method.present?
      payment.payment_method.update!(external_id: gateway_payer_id)
    end
    
    Rails.logger.info("Successfully processed payment #{payment.id}: #{transaction_id}")
    
    # Trigger any post-payment processing (notifications, accounting, etc.)
    process_payment_completion(payment)
    
  rescue => e
    Rails.logger.error("Error processing successful payment: #{e.message}")
    Rails.logger.error("Payment data: #{data.to_json}")
    raise e
  end
  
  # Process canceled/failed payment webhook
  def process_canceled_payment(data)
    payment = find_payment(data)
    return unless payment
    
    # Extract cancellation details
    transaction_id = data['transaction_id'] || data['TransactionId']
    code = data['code'] || data['Code']
    message = data['message'] || data['Message']
    
    # Determine failure reason
    failure_reason = determine_failure_reason(code, message)
    
    # Update payment record
    payment.update!(
      status: 'failed',
      external_id: transaction_id,
      failed_at: Time.current,
      failure_reason: failure_reason,
      gateway_response: data.to_json
    )
    
    Rails.logger.info("Payment #{payment.id} canceled: #{failure_reason}")
    
    # Trigger failure notifications
    process_payment_failure(payment, failure_reason)
    
  rescue => e
    Rails.logger.error("Error processing canceled payment: #{e.message}")
    Rails.logger.error("Payment data: #{data.to_json}")
    raise e
  end
  
  # Find payment record from webhook data
  def find_payment(data)
    payment_reference_id = data['payment_reference_id'] || data['PaymentReferenceId']
    
    if payment_reference_id.blank?
      Rails.logger.error("No payment_reference_id in webhook data")
      return nil
    end
    
    # Try to find by payment ID
    payment = Payment.find_by(id: payment_reference_id)
    
    if payment.nil?
      Rails.logger.error("Payment not found: #{payment_reference_id}")
      return nil
    end
    
    payment
  end
  
  # Determine failure reason from Zego response code
  def determine_failure_reason(code, message)
    code = code.to_i
    
    case code
    when 5 # CODE_CANCELLED
      'Payment was canceled'
    when 6 # CODE_RETURNED
      'ACH payment was returned by bank'
    when 2
      'Insufficient funds'
    when 3
      'Invalid account information'
    when 4
      'Payment declined by processor'
    else
      message.presence || 'Payment failed'
    end
  end
  
  # Process post-payment completion tasks
  def process_payment_completion(payment)
    # Send confirmation email/SMS to payer
    send_payment_confirmation(payment)
    
    # Update lease balance
    update_lease_balance(payment)
    
    # Record accounting transaction
    record_accounting_transaction(payment)
    
    # Trigger any webhooks or integrations
    notify_external_systems(payment)
    
  rescue => e
    # Log but don't fail the job - payment is already processed
    Rails.logger.error("Error in post-payment processing: #{e.message}")
  end
  
  # Process payment failure tasks
  def process_payment_failure(payment, reason)
    # Send failure notification to payer
    send_payment_failure_notification(payment, reason)
    
    # Notify property manager
    notify_property_manager_of_failure(payment, reason)
    
    # If ACH return, may need to retry or mark payment method as invalid
    handle_ach_return(payment) if reason.include?('returned')
    
  rescue => e
    # Log but don't fail the job
    Rails.logger.error("Error in payment failure processing: #{e.message}")
  end
  
  # Send payment confirmation to payer
  def send_payment_confirmation(payment)
    return unless payment.payer.present?
    
    # Use communication service to send confirmation
    CommunicationService.send_payment_confirmation(
      payment: payment,
      recipient: payment.payer,
      amount: payment.amount,
      method: payment.payment_method&.payment_type
    )
  end
  
  # Send payment failure notification
  def send_payment_failure_notification(payment, reason)
    return unless payment.payer.present?
    
    CommunicationService.send_payment_failure(
      payment: payment,
      recipient: payment.payer,
      amount: payment.amount,
      reason: reason
    )
  end
  
  # Update lease balance after successful payment
  def update_lease_balance(payment)
    return unless payment.lease.present?
    
    payment.lease.record_payment(payment.amount, payment.payment_at)
  end
  
  # Record accounting transaction
  def record_accounting_transaction(payment)
    # This would integrate with your accounting system
    # AccountingService.record_payment(payment)
    Rails.logger.info("Recording accounting transaction for payment #{payment.id}")
  end
  
  # Notify external systems of payment
  def notify_external_systems(payment)
    # Trigger any external webhooks or integrations
    Rails.logger.info("Notifying external systems of payment #{payment.id}")
  end
  
  # Notify property manager of failure
  def notify_property_manager_of_failure(payment, reason)
    return unless payment.property.present?
    
    # Send notification to property manager
    Rails.logger.info("Notifying property manager of failed payment #{payment.id}: #{reason}")
  end
  
  # Handle ACH return
  def handle_ach_return(payment)
    return unless payment.payment_method&.payment_type == 'ach'
    
    # Mark payment method as potentially invalid
    payment.payment_method.update!(
      has_failed_payment: true,
      last_failed_at: Time.current
    )
    
    Rails.logger.warn("ACH payment method #{payment.payment_method.id} has failed")
  end
end
