# app/models/concerns/notifiable_approval.rb
module NotifiableApproval
  extend ActiveSupport::Concern
  
  included do
    after_create :notify_approver,                  unless: -> { skip_notifications }
    after_update :notify_requester_on_completion,   unless: -> { skip_notifications }
  end
  
  private
  
  def notify_approver
    return unless approver.is_a?(User)
    return if approver == Current.user
    
    NotificationService.create(
      recipient: approver,
      notification_type: :approval_required,
      notifiable: self,
      actor: requester,
      message: "#{requester&.name || 'Someone'} requested your approval",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  end
  
  def notify_requester_on_completion
    return unless saved_change_to_status?
    return unless %w[approved rejected].include?(status)
    return unless requester.is_a?(User)
    return if requester == Current.user
    
    message = if status == 'approved'
      "#{approver&.name || 'Someone'} approved your request"
    else
      "#{approver&.name || 'Someone'} rejected your request"
    end
    
    NotificationService.create(
      recipient: requester,
      notification_type: :approval_completed,
      notifiable: self,
      actor: approver,
      message: message,
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  end
end
