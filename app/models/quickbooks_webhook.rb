# frozen_string_literal: true

class QuickbooksWebhook < ApplicationRecord
  belongs_to :company
  
  validates :realm_id, :event_name, presence: true
  
  scope :pending, -> { where(status: 'pending') }
  scope :processed, -> { where(status: 'processed') }
  scope :failed, -> { where(status: 'error') }
  
  MAX_RETRIES = 5
  
  def process!
    return if processed_at.present?
    return if retry_count >= MAX_RETRIES
    
    begin
      processor = QuickbooksWebhookProcessorService.new(self)
      result = processor.process
      
      if result[:success]
        mark_processed!
      else
        mark_error!(result[:error])
      end
    rescue => e
      mark_error!(e.message)
    end
  end
  
  def mark_processed!
    update!(
      status: 'processed',
      processed_at: Time.current
    )
  end
  
  def mark_error!(error_message)
    increment!(:retry_count)
    update!(
      status: 'error',
      processing_error: error_message
    )
  end
  
  def mark_ignored!(reason)
    update!(
      status: 'ignored',
      processing_error: reason,
      processed_at: Time.current
    )
  end
  
  class << self
    def cleanup_old(days = 30)
      where('created_at < ?', days.days.ago)
        .where(status: ['processed', 'ignored'])
        .delete_all
    end
    
    def process_batch(limit = 50)
      pending.order(created_at: :asc).limit(limit).each(&:process!)
    end
  end
end
