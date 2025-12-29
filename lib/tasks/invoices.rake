# frozen_string_literal: true

namespace :invoices do
  desc 'Send loan invoices that are due in 3 days'
  task auto_send: :environment do
    puts "[#{Time.current}] Starting loan invoice auto-send"
    
    # Find draft loan invoices due in 3 days
    invoices = Invoice.where(status: 'draft')
                      .where.not(loan_id: nil)
                      .where('due_date = ?', 3.days.from_now.to_date)
    
    if invoices.none?
      puts "No invoices to send (0 draft loan invoices due in 3 days)"
      next
    end
    
    puts "Found #{invoices.count} invoices to send"
    
    sent_count = 0
    error_count = 0
    
    invoices.each do |invoice|
      begin
        # Send email
        InvoiceMailer.invoice_email(invoice).deliver_now
        
        # Update status
        invoice.update!(status: 'sent', sent_at: Time.current)
        
        puts "✅ Sent: #{invoice.invoice_number} to #{invoice.contact&.email || 'NO EMAIL'}"
        sent_count += 1
        
      rescue => e
        puts "❌ Failed: #{invoice.invoice_number} - #{e.message}"
        Rails.logger.error "Invoice auto-send failed for Invoice ##{invoice.id}: #{e.message}"
        error_count += 1
      end
    end
    
    puts "\n[#{Time.current}] Invoice auto-send complete"
    puts "Summary: #{sent_count} sent, #{error_count} errors"
  end
  
  desc 'Send invoice reminders for overdue invoices'
  task send_reminders: :environment do
    puts "[#{Time.current}] Starting invoice reminder send"
    
    # Find sent invoices that are overdue
    invoices = Invoice.where(status: 'sent')
                      .where('due_date < ?', Date.current)
    
    if invoices.none?
      puts "No overdue invoices to remind"
      next
    end
    
    puts "Found #{invoices.count} overdue invoices"
    
    sent_count = 0
    
    invoices.each do |invoice|
      begin
        # Send reminder email
        InvoiceMailer.reminder_email(invoice).deliver_now
        
        puts "✅ Reminder sent: #{invoice.invoice_number}"
        sent_count += 1
        
      rescue => e
        puts "❌ Failed: #{invoice.invoice_number} - #{e.message}"
        Rails.logger.error "Invoice reminder failed for Invoice ##{invoice.id}: #{e.message}"
      end
    end
    
    puts "\n[#{Time.current}] Invoice reminders complete"
    puts "Summary: #{sent_count} reminders sent"
  end
end
