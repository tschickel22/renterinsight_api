# app/jobs/notification_reminders_job.rb
class NotificationRemindersJob < ApplicationJob
  queue_as :default

  # First-run guard for overdue-task notifications. Prevents a fresh deploy from
  # flooding every open overdue task at once. Fires from 2026-07-04 00:00 America/Denver
  # (06:00 UTC). Safe to remove after that date passes.
  OVERDUE_TASKS_NOT_BEFORE = Time.utc(2026, 7, 4, 6, 0, 0).freeze

  def perform
    notify_tasks_due_soon
    notify_overdue_tasks
    notify_overdue_invoices
  end

  private

  def notify_tasks_due_soon
    Task.where('due_date > ? AND due_date <= ?', Time.current, 24.hours.from_now)
        .where.not(status: [Task.statuses[:completed], Task.statuses[:cancelled]])
        .where.not(assigned_to_id: nil)
        .find_each do |task|
      next unless task.assigned_to.is_a?(User)

      already = Notification.where(
        recipient: task.assigned_to,
        notifiable: task,
        notification_type: 'task_due_soon'
      ).where('created_at > ?', 24.hours.ago).exists?
      next if already

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

  def notify_overdue_tasks
    return if Time.current < OVERDUE_TASKS_NOT_BEFORE

    Task.overdue.where.not(assigned_to_id: nil).find_each do |task|
      next unless task.assigned_to.is_a?(User)

      already = Notification.where(
        recipient: task.assigned_to,
        notifiable: task,
        notification_type: 'task_overdue'
      ).where('created_at > ?', 24.hours.ago).exists?
      next if already

      days_overdue = ((Time.current - task.due_date) / 1.day).ceil
      days_overdue = 1 if days_overdue < 1

      NotificationService.create(
        recipient: task.assigned_to,
        notification_type: :task_overdue,
        notifiable: task,
        message: "Task '#{task.title}' is #{days_overdue} #{'day'.pluralize(days_overdue)} overdue",
        deliver_now: true,
        company_id: task.company_id,
        location_id: task.location_id
      )
    end
  end

  # Push an overdue invoice to the customer's portal app and leave a
  # Notification row behind so the caller's 7-day guard sees it. Returns
  # quietly when the customer has no portal login.
  def notify_overdue_invoice_buyer(invoice)
    contact = invoice.contact
    access = BuyerPortalAccess.find_by(buyer_type: contact.class.name, buyer_id: contact.id)
    return if access.blank?

    days_overdue = (Date.today - invoice.due_date).to_i

    NotificationService.create(
      recipient: access,
      notification_type: :invoice_overdue,
      notifiable: invoice,
      message: "Invoice #{invoice.invoice_number} is #{days_overdue} #{'day'.pluralize(days_overdue)} past due",
      deliver_now: false,
      company_id: invoice.company_id,
      location_id: invoice.location_id
    )

    PortalPushService.invoice_overdue(invoice: invoice, buyer: contact)
  rescue => e
    Rails.logger.error("[NotificationRemindersJob] Portal overdue push failed for invoice #{invoice.id}: #{e.message}")
  end

  def notify_overdue_invoices
    overdue_invoices = Invoice.where('due_date < ?', Date.today)
                              .where(status: ['sent', 'pending'])

    overdue_invoices.find_each do |invoice|
      next unless invoice.contact.present?

      existing_notification = Notification.where(
        notifiable: invoice,
        notification_type: 'invoice_overdue'
      ).where('created_at > ?', 7.days.ago).exists?

      next if existing_notification

      # The customer hears about it too, in their portal app.
      #
      # This runs before the staff notifications below and outside their
      # finance_role branch, because a company without a finance_manager role
      # creates no Notification row at all, which would leave the 7-day guard
      # above permanently false and push the customer every single night.
      # Marking it here is what makes the guard cover this send.
      notify_overdue_invoice_buyer(invoice)

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
