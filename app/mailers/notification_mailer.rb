# app/mailers/notification_mailer.rb
class NotificationMailer < ApplicationMailer
  def broadcast_notification(user:, notification:)
    @user = user
    @notification = notification
    
    # Use broadcasting company for email settings (for cross-company broadcasts)
    broadcasting_company_id = notification.metadata['broadcasting_company_id'] || notification.company_id
    @company = Company.find_by(id: broadcasting_company_id) if broadcasting_company_id.present?
    @location = Location.find_by(id: notification.location_id) if notification.location_id.present?
    
    # Get frontend URL for links - hardcoded for development reliability
    @frontend_url = if Rails.env.production?
      ENV['FRONTEND_URL'] || 'https://app.renterinsight.com'
    else
      'https://localhost:5173'
    end
    
    Rails.logger.info "[NotificationMailer] Frontend URL: #{@frontend_url}"
    Rails.logger.info "[NotificationMailer] Action URL: #{notification.action_url}"
    
    # Build action button if action_url present
    @action_url = notification.action_url
    @action_text = notification.action_text || 'View Details'
    
    # Determine category icon/color
    @category_config = {
      'system' => { icon: '⚙️', color: '#6b7280' },
      'assignment' => { icon: '📋', color: '#3b82f6' },
      'activity' => { icon: '🔔', color: '#8b5cf6' },
      'communication' => { icon: '💬', color: '#06b6d4' },
      'financial' => { icon: '💰', color: '#10b981' },
      'alert' => { icon: '⚠️', color: '#f59e0b' },
      'service' => { icon: '🔧', color: '#ec4899' },
      'crm' => { icon: '👥', color: '#14b8a6' },
      'sales' => { icon: '💼', color: '#8b5cf6' },
      'finance' => { icon: '💰', color: '#10b981' },
      'broadcast' => { icon: '📢', color: '#f59e0b' }
    }[@notification.category] || { icon: '🔔', color: '#6b7280' }
    
    # Attach files if present
    if notification.attachments.attached?
      notification.attachments.each do |attachment|
        attachments[attachment.filename.to_s] = attachment.download
      end
    end
    
    mail(
      to: @user.email,
      from: default_from_address,
      subject: notification.title
    )
  end
end
