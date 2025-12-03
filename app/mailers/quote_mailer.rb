class QuoteMailer < ApplicationMailer
  # Send quote to client when company sends it
  def quote_sent(quote)
    @quote = quote
    @company = quote.company
    @location = quote.location
    @contact = quote.contact
    @account = quote.account
    
    # Calculate quote totals
    @subtotal = @quote.subtotal
    @tax = @quote.tax
    @total = @quote.total
    
    # Public link for viewing quote (no login required)
    @quote_link = @quote.public_link
    
    mail(
      to: @contact.email,
      from: default_from_address,
      subject: "Quote #{@quote.quote_number} from #{@company.name}"
    )
  end
  
  # Notify company when client accepts quote
  def client_accepted(quote)
    @quote = quote
    @company = quote.company
    @location = quote.location
    @contact = quote.contact
    @account = quote.account
    
    # Find company users to notify (admins, sales staff)
    recipients = find_notification_recipients(@company, @location)
    
    return if recipients.empty?
    
    mail(
      to: recipients,
      from: default_from_address,
      subject: "Quote #{@quote.quote_number} Accepted by #{@contact.full_name}"
    )
  end
  
  # Notify company when client rejects quote
  def client_rejected(quote, reason = nil)
    @quote = quote
    @company = quote.company
    @location = quote.location
    @contact = quote.contact
    @account = quote.account
    @rejection_reason = reason
    
    # Find company users to notify (admins, sales staff)
    recipients = find_notification_recipients(@company, @location)
    
    return if recipients.empty?
    
    mail(
      to: recipients,
      from: default_from_address,
      subject: "Quote #{@quote.quote_number} Declined by #{@contact.full_name}"
    )
  end
  
  private
  
  def find_notification_recipients(company, location = nil)
    # Get users who should be notified
    recipients = []
    
    if location.present?
      # Location-specific notifications: location admins and assigned sales staff
      location_users = User.where(company_id: company.id)
                          .joins(:user_locations)
                          .where(user_locations: { location_id: location.id, active: true })
                          .where(user_locations: { location_role: ['location_admin', 'location_manager'] })
                          .pluck(:email)
      
      recipients += location_users
    end
    
    # Always include company admins
    admin_users = User.where(company_id: company.id, role: ['admin', 'super_admin', 'platform_admin'])
                     .pluck(:email)
    
    recipients += admin_users
    
    # Remove duplicates and blanks
    recipients.compact.uniq
  end
end
