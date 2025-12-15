# app/jobs/notification_reminders_job.rb
class NotificationRemindersJob < ApplicationJob
  queue_as :default
  
  def perform
    # Find tasks due in next 24 hours that haven't been notified
    notify_tasks_due_soon
    
    # Find overdue invoices that haven't been notified recently
    notify_overdue_invoices
  end
  
  private
  
  def notify_tasks_due_soon
    # Find tasks due in next 24 hours
    tasks_due_soon = Task.where('due_date > ? AND due_date <= ?', Time.current, 24.hours.from_now)
                         .where(completed: false)
    
    tasks_due_soon.each do |task|
      next unless task.assigned_to.is_a?(User)
      
      # Check if we've already sent a notification for this task today
      existing_notification = Notification.where(
        recipient: task.assigned_to,
        notifiable: task,
        notification_type: 'task_due_soon'
      ).where('created_at > ?', 24.hours.ago).exists?
      
      next if existing_notification
      
      # Create notification
      NotificationService.create(
        recipient: task.assigned_to,
        notification_type: :task_due_soon,
        notifiable: task,
        message: "Task '#{task.title}' is due on #{task.due_date.strftime('%B %d at %I:%M %p')}",
        deliver_now: true,
        company_id: task.company_id,
        location_id: task.location_id
      )
    end
  end
  
  def notify_overdue_invoices
    # Find invoices that are overdue and unpaid
    overdue_invoices = Invoice.where('due_date < ?', Date.today)
                              .where(status: ['sent', 'pending'])
    
    overdue_invoices.each do |invoice|
      next unless invoice.contact.present?
      
      # Check if we've already sent a notification for this invoice this week
      existing_notification = Notification.where(
        notifiable: invoice,
        notification_type: 'invoice_overdue'
      ).where('created_at > ?', 7.days.ago).exists?
      
      next if existing_notification
      
      # Find finance team members to notify
      company = Company.find(invoice.company_id)
      finance_role = Role.find_by(name: 'finance_manager', company: company)
      
      if finance_role
        finance_users = User.joins(:user_role_assignments)
                           .where(user_role_assignments: { role_id: finance_role.id })
                           .where(company_id: invoice.company_id)
        
        finance_users.each do |user|
          NotificationService.create(
            recipient: user,
            notification_type: :invoice_overdue,
            notifiable: invoice,
            message: "Invoice #{invoice.invoice_number} for #{invoice.contact.name} is #{(Date.today - invoice.due_date).to_i} days overdue",
            deliver_now: true,
            company_id: invoice.company_id,
            location_id: invoice.location_id
          )
        end
      end
    end
  end
end
