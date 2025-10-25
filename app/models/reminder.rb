# frozen_string_literal: true
class Reminder < ApplicationRecord
  self.table_name = 'reminders'
  belongs_to :lead
  belongs_to :user, optional: true

  validates :title, presence: true
  validates :reminder_type, inclusion: { in: %w[call email task follow_up other], allow_nil: true }

  scope :upcoming, -> { where(is_completed: [false, nil]).order(due_date: :asc) }
  
  after_create :broadcast_popup_notification

  def complete!
    update!(is_completed: true)
  end
  
  private
  
  def broadcast_popup_notification
    # Broadcast popup notification immediately when reminder is created
    return unless user_id.present?
    return if is_completed
    
    ActionCable.server.broadcast(
      "user_notifications_#{user_id}",
      {
        type: 'activity_notification',
        activity: {
          id: id,
          type: reminder_type || 'reminder',
          subject: title,
          description: description,
          priority: priority || 'medium',
          dueDate: due_date&.iso8601,
          leadName: "#{lead.first_name} #{lead.last_name}",
          leadId: lead.id
        },
        settings: {
          isEnabled: true,
          showReminders: true,
          showActivityUpdates: true,
          autoClose: true,
          autoCloseDelay: 5000
        }
      }
    )
    
    Rails.logger.info "[Reminder] Broadcast popup notification for reminder #{id} to user #{user_id}"
  rescue => e
    Rails.logger.error "[Reminder] Failed to broadcast popup: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
end
