# app/models/concerns/notifiable_payment.rb
module NotifiablePayment
  extend ActiveSupport::Concern
  
  included do
    after_create :notify_on_payment_received, unless: -> { skip_notifications }
    after_update :notify_on_payment_failed,   unless: -> { skip_notifications }
  end
  
  private
  
  def notify_on_payment_received
    return unless status == 'completed'
    
    # Notify finance team
    finance_role = Role.find_by(name: 'finance_manager', company_id: company_id)
    if finance_role
      User.joins(:user_role_assignments)
          .where(user_role_assignments: { role_id: finance_role.id })
          .where(company_id: company_id)
          .each do |manager|
        
        NotificationService.create(
          recipient: manager,
          notification_type: :payment_received,
          notifiable: self,
          message: "Payment of #{ActionController::Base.helpers.number_to_currency(amount || 0)} received",
          deliver_now: false,
          company_id: company_id,
          location_id: location_id
        )
      end
    end
  end
  
  def notify_on_payment_failed
    return unless saved_change_to_status? && status == 'failed'
    
    # Notify finance team
    finance_role = Role.find_by(name: 'finance_manager', company_id: company_id)
    if finance_role
      User.joins(:user_role_assignments)
          .where(user_role_assignments: { role_id: finance_role.id })
          .where(company_id: company_id)
          .each do |manager|
        
        NotificationService.create(
          recipient: manager,
          notification_type: :payment_failed,
          notifiable: self,
          message: "Payment of #{ActionController::Base.helpers.number_to_currency(amount || 0)} failed",
          deliver_now: true,
          company_id: company_id,
          location_id: location_id
        )
      end
    end
  end
end
