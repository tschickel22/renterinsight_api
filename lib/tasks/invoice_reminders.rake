# frozen_string_literal: true
# Rake tasks for sending invoice reminders
# Schedule via cron: 0 9 * * * cd /app && rake invoices:send_upcoming_reminders

namespace :invoices do
  desc "Send email reminders for upcoming loan invoices (3 days before due)"
  task send_upcoming_reminders: :environment do
    puts "=" * 80
    puts "Sending Invoice Reminders - #{Time.current}"
    puts "=" * 80
    
    # Find draft loan invoices due in 3 days
    reminder_date = Date.current + 3.days
    
    invoices_to_send = Invoice
      .where(status: 'draft')
      .where.not(loan_id: nil)
      .where(due_date: reminder_date)
      .where.not(contact_id: nil)
      .includes(:contact, :loan, :company, :location)
    
    puts "\nFound #{invoices_to_send.count} loan invoices due on #{reminder_date.strftime('%B %d, %Y')}"
    
    if invoices_to_send.none?
      puts "✓ No invoices to send today"
      puts "=" * 80
      exit 0
    end
    
    sent_count = 0
    error_count = 0
    
    invoices_to_send.find_each do |invoice|
      begin
        contact = invoice.contact
        
        unless contact.email.present?
          puts "  ⚠️  Skipping invoice #{invoice.invoice_number} - no email for contact #{contact.full_name}"
          next
        end
        
        puts "  📧 Sending invoice #{invoice.invoice_number} to #{contact.full_name} (#{contact.email})"
        
        # Send email
        InvoiceMailer.invoice_email(invoice).deliver_now
        
        # Update status to 'sent'
        invoice.update!(status: 'sent')
        
        puts "     ✓ Sent successfully"
        sent_count += 1
        
      rescue => e
        puts "     ✗ Error: #{e.message}"
        Rails.logger.error "[InvoiceReminders] Failed to send invoice #{invoice.id}: #{e.message}"
        Rails.logger.error e.backtrace.first(3).join("\n")
        error_count += 1
      end
    end
    
    puts "\n" + "=" * 80
    puts "Summary:"
    puts "  Sent: #{sent_count}"
    puts "  Errors: #{error_count}"
    puts "  Total: #{invoices_to_send.count}"
    puts "=" * 80
  end
  
  desc "Send email reminders for overdue invoices"
  task send_overdue_reminders: :environment do
    puts "=" * 80
    puts "Sending Overdue Invoice Reminders - #{Time.current}"
    puts "=" * 80
    
    # Find sent/viewed invoices that are past due
    overdue_invoices = Invoice
      .where(status: ['sent', 'viewed'])
      .where('due_date < ?', Date.current)
      .where.not(contact_id: nil)
      .includes(:contact, :company, :location)
    
    puts "\nFound #{overdue_invoices.count} overdue invoices"
    
    if overdue_invoices.none?
      puts "✓ No overdue invoices"
      puts "=" * 80
      exit 0
    end
    
    sent_count = 0
    error_count = 0
    
    overdue_invoices.find_each do |invoice|
      begin
        contact = invoice.contact
        
        unless contact.email.present?
          puts "  ⚠️  Skipping invoice #{invoice.invoice_number} - no email"
          next
        end
        
        days_overdue = (Date.current - invoice.due_date).to_i
        puts "  📧 Sending overdue reminder #{invoice.invoice_number} to #{contact.full_name} (#{days_overdue} days overdue)"
        
        # Send overdue reminder (you'll need to create this mailer method)
        InvoiceMailer.overdue_reminder(invoice).deliver_now
        
        # Update status to 'overdue' if not already
        invoice.update!(status: 'overdue') unless invoice.status == 'overdue'
        
        puts "     ✓ Sent successfully"
        sent_count += 1
        
      rescue => e
        puts "     ✗ Error: #{e.message}"
        Rails.logger.error "[InvoiceReminders] Failed to send overdue reminder #{invoice.id}: #{e.message}"
        error_count += 1
      end
    end
    
    puts "\n" + "=" * 80
    puts "Summary:"
    puts "  Sent: #{sent_count}"
    puts "  Errors: #{error_count}"
    puts "  Total: #{overdue_invoices.count}"
    puts "=" * 80
  end
end
