# frozen_string_literal: true

class SendCommunicationJob < ApplicationJob
  queue_as :communications
  
  # Retry with exponential backoff for transient failures
  retry_on StandardError, wait: :exponentially_longer, attempts: 3
  
  def perform(communication_id, options = {})
    Rails.logger.info("SendCommunicationJob: Sending communication #{communication_id}")
    
    communication = Communication.find(communication_id)
    
    # Check if already sent
    if communication.sent? || communication.delivered?
      Rails.logger.warn("Communication #{communication_id} already sent, skipping")
      return
    end
    
    # Send the communication
    result = CommunicationService.send_communication(communication, options)
    
    if result[:success]
      Rails.logger.info("Successfully sent communication #{communication_id} via #{result[:provider]}")
    else
      Rails.logger.error("Failed to send communication #{communication_id}: #{result[:error]}")
      communication.mark_as_failed!(result[:error])
      raise StandardError, result[:error] # This will trigger retry
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("Communication #{communication_id} not found: #{e.message}")
    # Don't retry if record doesn't exist
  rescue => e
    Rails.logger.error("Error in SendCommunicationJob for communication #{communication_id}: #{e.message}")
    communication.mark_as_failed!(e.message) if communication
    raise # Trigger retry
  end
end
