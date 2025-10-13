# frozen_string_literal: true

class SchedulingService
  VALID_STATUSES = %w[immediate scheduled sent cancelled failed].freeze
  
  class << self
    # Schedule a communication to be sent at a specific time
    def schedule(communication, send_at:)
      raise ArgumentError, "send_at must be in the future" if send_at <= Time.current
      raise ArgumentError, "Communication already sent" if communication.sent?
      
      # Cancel any existing scheduled job
      cancel_existing_job(communication) if communication.scheduled_job_id.present?
      
      # Schedule the job
      job = ScheduledCommunicationJob.set(wait_until: send_at).perform_later(communication.id)
      
      # Update communication
      communication.update!(
        scheduled_for: send_at,
        scheduled_status: 'scheduled',
        scheduled_job_id: job.job_id
      )
      
      Rails.logger.info("Scheduled communication #{communication.id} for #{send_at}")
      
      {
        success: true,
        scheduled_for: send_at,
        job_id: job.job_id
      }
    rescue => e
      Rails.logger.error("Failed to schedule communication #{communication.id}: #{e.message}")
      {
        success: false,
        error: e.message
      }
    end
    
    # Cancel a scheduled communication
    def cancel(communication)
      unless communication.scheduled?
        return {
          success: false,
          error: "Communication is not scheduled"
        }
      end
      
      # Cancel the Sidekiq job
      cancel_existing_job(communication)
      
      # Update communication
      communication.update!(
        scheduled_status: 'cancelled',
        scheduled_job_id: nil
      )
      
      Rails.logger.info("Cancelled scheduled communication #{communication.id}")
      
      {
        success: true,
        message: "Communication cancelled"
      }
    rescue => e
      Rails.logger.error("Failed to cancel communication #{communication.id}: #{e.message}")
      {
        success: false,
        error: e.message
      }
    end
    
    # Reschedule a communication to a new time
    def reschedule(communication, new_time:)
      unless communication.scheduled?
        return {
          success: false,
          error: "Communication is not scheduled"
        }
      end
      
      raise ArgumentError, "new_time must be in the future" if new_time <= Time.current
      
      # Cancel existing job
      cancel_existing_job(communication)
      
      # Schedule new job
      job = ScheduledCommunicationJob.set(wait_until: new_time).perform_later(communication.id)
      
      # Update communication
      communication.update!(
        scheduled_for: new_time,
        scheduled_job_id: job.job_id
      )
      
      Rails.logger.info("Rescheduled communication #{communication.id} to #{new_time}")
      
      {
        success: true,
        scheduled_for: new_time,
        job_id: job.job_id
      }
    rescue => e
      Rails.logger.error("Failed to reschedule communication #{communication.id}: #{e.message}")
      {
        success: false,
        error: e.message
      }
    end
    
    # Process a scheduled communication (called by the job)
    def process_scheduled(communication_id)
      communication = Communication.find(communication_id)
      
      unless communication.scheduled?
        Rails.logger.warn("Communication #{communication_id} is not scheduled, skipping")
        return { success: false, error: "Not scheduled" }
      end
      
      # Update status to indicate processing
      communication.update!(scheduled_status: 'sending')
      
      # Send the communication
      result = CommunicationService.send_communication(communication)
      
      if result[:success]
        communication.update!(scheduled_status: 'sent')
        Rails.logger.info("Successfully sent scheduled communication #{communication_id}")
      else
        communication.update!(scheduled_status: 'failed')
        Rails.logger.error("Failed to send scheduled communication #{communication_id}: #{result[:error]}")
      end
      
      result
    rescue => e
      communication.update!(scheduled_status: 'failed') if communication
      Rails.logger.error("Error processing scheduled communication #{communication_id}: #{e.message}")
      { success: false, error: e.message }
    end
    
    # Get all scheduled communications that are ready to send
    def ready_to_send
      Communication
        .where(scheduled_status: 'scheduled')
        .where('scheduled_for <= ?', Time.current)
        .order(:scheduled_for)
    end
    
    # Get upcoming scheduled communications
    def upcoming(limit: 10)
      Communication
        .where(scheduled_status: 'scheduled')
        .where('scheduled_for > ?', Time.current)
        .order(:scheduled_for)
        .limit(limit)
    end
    
    # Process any missed scheduled communications
    # This is a safety net in case jobs fail
    def process_missed
      ready_to_send.each do |communication|
        Rails.logger.warn("Processing missed scheduled communication #{communication.id}")
        SendCommunicationJob.perform_later(communication.id)
      end
    end
    
    private
    
    # Cancel existing Sidekiq job
    def cancel_existing_job(communication)
      return unless communication.scheduled_job_id.present?
      
      begin
        # Try to find and delete the job from Sidekiq
        Sidekiq::ScheduledSet.new.each do |job|
          if job.jid == communication.scheduled_job_id
            job.delete
            Rails.logger.info("Deleted Sidekiq job #{communication.scheduled_job_id}")
            break
          end
        end
      rescue => e
        Rails.logger.error("Error cancelling Sidekiq job: #{e.message}")
      end
    end
  end
end
