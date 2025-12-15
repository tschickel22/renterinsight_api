# app/models/concerns/notifiable_task.rb
module NotifiableTask
  extend ActiveSupport::Concern
  
  included do
    after_create :notify_assigned_user
    after_update :notify_on_reassignment
  end
  
  # Class method for background job to call
  def self.notify_tasks_due_soon
    # This is now handled by NotificationRemindersJob
    # Keeping this method for backward compatibility
    NotificationRemindersJob.perform_now
  end
  
  private
  
  def notify_assigned_user
    return unless assigned_to.is_a?(User) && assigned_to != Current.user
    
    NotificationService.create(
      recipient: assigned_to,
      notification_type: :task_assigned,
      notifiable: self,
      actor: Current.user,
      message: "#{Current.user&.name || 'Someone'} assigned you a task: #{title}",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  end
  
  def notify_on_reassignment
    return unless saved_change_to_assigned_to_id?
    return unless assigned_to.is_a?(User) && assigned_to != Current.user
    
    NotificationService.create(
      recipient: assigned_to,
      notification_type: :task_assigned,
      notifiable: self,
      actor: Current.user,
      message: "#{Current.user&.name || 'Someone'} reassigned task '#{title}' to you",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  end
end
