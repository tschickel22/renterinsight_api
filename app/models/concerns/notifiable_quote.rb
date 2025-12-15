# app/models/concerns/notifiable_quote.rb
module NotifiableQuote
  extend ActiveSupport::Concern
  
  included do
    after_update :notify_on_status_change
  end
  
  private
  
  def notify_on_status_change
    return unless saved_change_to_status?
    
    case status
    when 'accepted'
      notify_quote_accepted
    when 'rejected'
      notify_quote_rejected
    end
  end
  
  def notify_quote_accepted
    # Notify the assigned salesperson
    if assigned_to.is_a?(User)
      NotificationService.create(
        recipient: assigned_to,
        notification_type: :quote_accepted,
        notifiable: self,
        message: "Quote #{quote_number} has been accepted by #{contact&.name || 'the customer'}",
        deliver_now: true,
        company_id: company_id,
        location_id: location_id
      )
    end
    
    # Also notify sales managers
    sales_manager_role = Role.find_by(name: 'sales_manager', company_id: company_id)
    if sales_manager_role
      User.joins(:user_role_assignments)
          .where(user_role_assignments: { role_id: sales_manager_role.id })
          .where(company_id: company_id)
          .each do |manager|
        next if manager == assigned_to # Don't notify twice
        
        NotificationService.create(
          recipient: manager,
          notification_type: :quote_accepted,
          notifiable: self,
          message: "Quote #{quote_number} has been accepted by #{contact&.name || 'the customer'}",
          deliver_now: true,
          company_id: company_id,
          location_id: location_id
        )
      end
    end
  end
  
  def notify_quote_rejected
    return unless assigned_to.is_a?(User)
    
    NotificationService.create(
      recipient: assigned_to,
      notification_type: :quote_rejected,
      notifiable: self,
      message: "Quote #{quote_number} was declined by #{contact&.name || 'the customer'}",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  end
end
