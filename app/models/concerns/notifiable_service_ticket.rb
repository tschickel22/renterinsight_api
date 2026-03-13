# app/models/concerns/notifiable_service_ticket.rb
module NotifiableServiceTicket
  extend ActiveSupport::Concern
  
  included do
    # Transient flag to skip notifications (used by bulk operations)
    attr_accessor :skip_notifications

    after_create :notify_assigned_user
    after_update :notify_on_assignment_change
    after_update :notify_on_completion
  end
  
  private
  
  def notify_assigned_user
    return if skip_notifications
    user = assigned_to_user
    return unless user.present? && user != Current.user
    
    NotificationService.create(
      recipient: user,
      notification_type: :service_ticket_assigned,
      notifiable: self,
      actor: Current.user,
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  end
  
  def notify_on_assignment_change
    return if skip_notifications
    return unless saved_change_to_assigned_to?
    user = assigned_to_user
    return unless user.present? && user != Current.user
    
    NotificationService.create(
      recipient: user,
      notification_type: :service_ticket_assigned,
      notifiable: self,
      actor: Current.user,
      message: "#{Current.user&.name || 'Someone'} reassigned service ticket ##{id} to you",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  end
  
  def notify_on_completion
    return if skip_notifications
    return unless saved_change_to_status? && status == 'completed'
    user = created_by_user
    return unless user.present? && user != Current.user
    
    NotificationService.create(
      recipient: user,
      notification_type: :service_ticket_completed,
      notifiable: self,
      actor: Current.user,
      message: "Service ticket ##{id} has been marked as completed",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  end
end
