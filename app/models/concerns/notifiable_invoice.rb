# app/models/concerns/notifiable_invoice.rb
module NotifiableInvoice
  extend ActiveSupport::Concern
  
  included do
    after_update :notify_on_invoice_sent
  end
  
  # Class method for background job to call
  def self.notify_overdue_invoices
    # This is now handled by NotificationRemindersJob
    # Keeping this method for backward compatibility
    NotificationRemindersJob.perform_now
  end
  
  private
  
  def notify_on_invoice_sent
    return unless saved_change_to_status? && status == 'sent'

    # Push to the customer's portal app. Separate from the finance-team
    # notification below, which goes to staff.
    begin
      PortalPushService.new_invoice(invoice: self, buyer: contact)
    rescue => e
      Rails.logger.error("[NotifiableInvoice] Portal push failed for invoice #{id}: #{e.message}")
    end

    # Notify finance team
    finance_role = Role.find_by(name: 'finance_manager', company_id: company_id)
    if finance_role
      User.joins(:user_role_assignments)
          .where(user_role_assignments: { role_id: finance_role.id })
          .where(company_id: company_id)
          .each do |manager|
        
        NotificationService.create(
          recipient: manager,
          notification_type: :invoice_sent,
          notifiable: self,
          message: "Invoice #{invoice_number} sent to #{contact&.name || 'customer'}",
          deliver_now: false,
          company_id: company_id,
          location_id: location_id
        )
      end
    end
  end
end
