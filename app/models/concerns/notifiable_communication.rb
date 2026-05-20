# app/models/concerns/notifiable_communication.rb
module NotifiableCommunication
  extend ActiveSupport::Concern
  
  included do
    after_create :notify_on_portal_message,   unless: -> { skip_notifications }
    after_create :notify_on_internal_message, unless: -> { skip_notifications }
  end
  
  private
  
  def notify_on_portal_message
    return unless direction == 'inbound' && communication_type == 'portal_message'
    
    # Find the user assigned to this entity (contact, account, etc.)
    assigned_user = find_assigned_user
    return unless assigned_user
    
    NotificationService.create(
      recipient: assigned_user,
      notification_type: :message_received,
      notifiable: self,
      message: "New message from #{from_email || from_phone}",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  end
  
  def notify_on_internal_message
    return unless direction == 'internal'
    return unless to_user.is_a?(User)
    
    NotificationService.create(
      recipient: to_user,
      notification_type: :message_received,
      notifiable: self,
      actor: from_user,
      message: "#{from_user&.name || 'Someone'} sent you a message",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  end
  
  def find_assigned_user
    # Try to find assigned user based on communicable entity
    return nil unless communicable.present?
    
    if communicable.respond_to?(:assigned_to)
      communicable.assigned_to
    elsif communicable.respond_to?(:user)
      communicable.user
    else
      nil
    end
  end
end
