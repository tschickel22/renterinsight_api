# frozen_string_literal: true

class BuyerPortalMailer < ApplicationMailer
  default from: ENV.fetch('PORTAL_FROM_EMAIL', 'portal@renterinsight.com')
  
  # Welcome email when buyer first gets portal access
  def welcome_email(buyer_access)
    @buyer_access = buyer_access
    @buyer = buyer_access.buyer
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    @portal_url = ENV.fetch('PORTAL_URL', 'https://portal.renterinsight.com')
    
    message = mail(
      to: buyer_access.email,
      subject: "Welcome to #{@company_name} Buyer Portal"
    )
    
    Rails.logger.info "Welcome email sent to #{buyer_access.email}"
    message
  end
  
  # Magic link for passwordless login
  def magic_link_email(buyer_access)
    @buyer_access = buyer_access
    @buyer = buyer_access.buyer
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    @portal_url = ENV.fetch('PORTAL_URL', 'https://portal.renterinsight.com')
    @magic_link = "#{@portal_url}/auth/magic-link?token=#{buyer_access.login_token}"
    @expires_in = '15 minutes'
    
    mail(
      to: buyer_access.email,
      subject: "Your Magic Link to #{@company_name} Portal"
    )
  end
  
  # Password reset email
  def password_reset_email(buyer_access)
    @buyer_access = buyer_access
    @buyer = buyer_access.buyer
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    @portal_url = ENV.fetch('PORTAL_URL', 'https://portal.renterinsight.com')
    @reset_link = "#{@portal_url}/auth/reset-password?token=#{buyer_access.reset_token}"
    @expires_in = '1 hour'
    
    mail(
      to: buyer_access.email,
      subject: "Reset Your #{@company_name} Portal Password"
    )
  end
  
  # Quote acceptance confirmation
  def quote_acceptance_email(quote, buyer_access)
    @quote = quote
    @buyer_access = buyer_access
    @buyer = buyer_access.buyer
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    @portal_url = ENV.fetch('PORTAL_URL', 'https://portal.renterinsight.com')
    @quote_url = "#{@portal_url}/quotes/#{quote.id}"
    
    mail(
      to: buyer_access.email,
      subject: "Quote #{quote.quote_number} Accepted - Thank You!"
    )
  end
  
  # Internal notification for quote rejection
  def quote_rejection_notification(quote, buyer_access)
    @quote = quote
    @buyer_access = buyer_access
    @buyer = buyer_access.buyer
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    @admin_url = ENV.fetch('ADMIN_URL', 'https://admin.renterinsight.com')
    @quote_url = "#{@admin_url}/quotes/#{quote.id}"
    
    mail(
      to: ENV.fetch('SALES_EMAIL', 'sales@renterinsight.com'),
      subject: "Quote #{quote.quote_number} Rejected by #{buyer_access.buyer.full_name rescue buyer_access.email}"
    )
  end
  
  # Internal notification when buyer replies in portal
  def communication_reply_notification(communication)
    @communication = communication
    @buyer = communication.communicable
    @thread = communication.communication_thread
    @company_name = ENV.fetch('COMPANY_NAME', 'RenterInsight')
    @admin_url = ENV.fetch('ADMIN_URL', 'https://admin.renterinsight.com')
    @thread_url = "#{@admin_url}/communications/threads/#{@thread.id}"
    
    buyer_name = @buyer.respond_to?(:full_name) ? @buyer.full_name : @buyer.email
    
    message = mail(
      to: ENV.fetch('SUPPORT_EMAIL', 'support@renterinsight.com'),
      subject: "New Reply from #{buyer_name} in Portal"
    )
    
    Rails.logger.info "Reply notification sent for thread: #{@thread.id}"
    message
  end
end
