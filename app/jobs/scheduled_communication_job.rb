# frozen_string_literal: true

class ScheduledCommunicationJob < ApplicationJob
  queue_as :communications
  
  # Retry with exponential backoff
  retry_on StandardError, wait: :exponentially_longer, attempts: 3
  
  def perform(communication_id)
    Rails.logger.info("Processing scheduled communication #{communication_id}")
    
    # Find communication
    communication = Communication.find_by(id: communication_id)
    unless communication
      Rails.logger.warn("Communication #{communication_id} not found, skipping")
      return
    end
    
    # Process the scheduled communication
    result = SchedulingService.process_scheduled(communication_id)
    
    if result[:success]
      Rails.logger.info("Successfully processed scheduled communication #{communication_id}")
    else
      Rails.logger.error("Failed to process scheduled communication #{communication_id}: #{result[:error]}")
      raise StandardError, result[:error] # This will trigger retry
    end
  rescue => e
    Rails.logger.error("Error in ScheduledCommunicationJob for communication #{communication_id}: #{e.message}")
    raise # Trigger retry
  end
end
