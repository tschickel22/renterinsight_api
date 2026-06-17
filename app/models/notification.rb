# app/models/notification.rb
class Notification < ApplicationRecord
  # Active Storage attachments
  has_many_attached :attachments
  
  # Polymorphic associations
  belongs_to :recipient, polymorphic: true
  belongs_to :notifiable, polymorphic: true, optional: true
  belongs_to :actor, polymorphic: true, optional: true
  
  # Tenant scoping
  belongs_to :company
  belongs_to :location, optional: true
  
  # Scopes
  scope :unread, -> { where(read: false) }
  scope :read, -> { where(read: true) }
  scope :by_category, ->(category) { where(category: category) }
  scope :by_type, ->(type) { where(notification_type: type) }
  scope :priority_order, -> { order(Arel.sql("CASE priority WHEN 'urgent' THEN 1 WHEN 'high' THEN 2 WHEN 'normal' THEN 3 WHEN 'low' THEN 4 END"), created_at: :desc) }
  scope :recent, -> { order(created_at: :desc) }
  
  # Validations
  validates :recipient_type, :recipient_id, :notification_type, :category, :title, :message, presence: true
  validates :priority, inclusion: { in: %w[urgent high normal low] }
  validates :category, inclusion: { in: %w[service crm sales finance system broadcast communications ai] }
  
  # Notification types with their default settings
  TYPES = {
    # Service notifications
    service_ticket_assigned: { category: 'service', priority: 'high', title: 'Service Ticket Assigned' },
    service_ticket_updated: { category: 'service', priority: 'normal', title: 'Service Ticket Updated' },
    service_ticket_completed: { category: 'service', priority: 'normal', title: 'Service Ticket Completed' },
    
    # Warranty Claim notifications
    warranty_claim_assigned: { category: 'service', priority: 'normal', title: 'Warranty Claim Assigned' },
    warranty_claim_status_changed: { category: 'service', priority: 'normal', title: 'Warranty Claim Status Update' },
    
    # CRM notifications
    lead_assigned: { category: 'crm', priority: 'high', title: 'Lead Assigned to You' },
    contact_assigned: { category: 'crm', priority: 'normal', title: 'Contact Assigned to You' },
    account_assigned: { category: 'crm', priority: 'normal', title: 'Account Assigned to You' },
    contact_updated: { category: 'crm', priority: 'low', title: 'Contact Information Updated' },
    task_assigned: { category: 'crm', priority: 'high', title: 'Task Assigned to You' },
    task_due_soon: { category: 'crm', priority: 'high', title: 'Task Due Soon' },
    activity_reminder: { category: 'crm', priority: 'normal', title: 'Activity Reminder' },
    
    # Sales notifications
    deal_assigned: { category: 'sales', priority: 'high', title: 'Deal Assigned to You' },
    quote_accepted: { category: 'sales', priority: 'high', title: 'Quote Accepted' },
    quote_rejected: { category: 'sales', priority: 'normal', title: 'Quote Rejected' },
    deal_stage_changed: { category: 'sales', priority: 'normal', title: 'Deal Stage Changed' },
    deal_won: { category: 'sales', priority: 'high', title: 'Deal Won!' },
    deal_lost: { category: 'sales', priority: 'normal', title: 'Deal Lost' },
    home_sold_choose_new_home: { category: 'sales', priority: 'high', title: 'Home Sold — Choose a New Home' },
    
    # Finance notifications
    payment_received: { category: 'finance', priority: 'normal', title: 'Payment Received' },
    payment_failed: { category: 'finance', priority: 'high', title: 'Payment Failed' },
    invoice_sent: { category: 'finance', priority: 'normal', title: 'Invoice Sent' },
    invoice_overdue: { category: 'finance', priority: 'high', title: 'Invoice Overdue' },
    
    # System notifications
    message_received: { category: 'system', priority: 'normal', title: 'New Message' },
    mention_received: { category: 'system', priority: 'normal', title: 'You Were Mentioned' },
    approval_required: { category: 'system', priority: 'high', title: 'Approval Required' },
    approval_completed: { category: 'system', priority: 'normal', title: 'Approval Completed' },
    
    # Broadcast notifications
    broadcast_message: { category: 'broadcast', priority: 'normal', title: 'Company Announcement' },
    system_alert: { category: 'broadcast', priority: 'urgent', title: 'System Alert' },

    # SMS / Communications notifications
    sms_reply_received: { category: 'communications', priority: 'high', title: 'SMS Reply Received' },
    email_reply_received: { category: 'communications', priority: 'high', title: 'Email Reply Received' },
    sms_cap_alert: { category: 'system', priority: 'normal', title: 'SMS Usage Alert' },

    # Project / Contractor notifications
    contractor_review_submitted: { category: 'service', priority: 'high', title: 'Contractor Submitted for Review' },
    contractor_review_approved: { category: 'service', priority: 'normal', title: 'Work Approved' },
    contractor_review_revision: { category: 'service', priority: 'high', title: 'Revision Requested' },
    contractor_review_rejected: { category: 'service', priority: 'normal', title: 'Work Rejected' },
    contractor_task_assigned: { category: 'service', priority: 'high', title: 'New Task Assignment' },
    project_phase_completed: { category: 'service', priority: 'normal', title: 'Project Phase Completed' },
    contractor_work_log_added: { category: 'service', priority: 'low', title: 'Work Log Entry Added' }
  }.freeze
  
  # Mark notification as read
  def mark_as_read!
    update!(read: true, read_at: Time.current)
  end
  
  # Mark notification as unread
  def mark_as_unread!
    update!(read: false, read_at: nil)
  end
  
  # Compute action URL if not explicitly set
  def computed_action_url
    return action_url if action_url.present?
    return nil unless notifiable.present?
    
    case notifiable_type
    when 'ServiceTicket'
      "/service/tickets/#{notifiable_id}"
    when 'WarrantyClaim'
      "/warranty/claims/#{notifiable_id}"
    when 'Lead'
      "/crm/leads/#{notifiable_id}?tab=activities"
    when 'Contact'
      "/contacts/#{notifiable_id}?tab=activities"
    when 'Account'
      "/accounts/#{notifiable_id}?tab=activities"
    when 'Deal'
      "/deals/#{notifiable_id}"
    when 'Quote'
      "/quotes/#{notifiable_id}"
    when 'Payment'
      "/finance/payments/#{notifiable_id}"
    when 'Invoice'
      "/finance/invoices/#{notifiable_id}"
    when 'Task'
      "/tasks/#{notifiable_id}"
    when 'Communication'
      "/portal/messages"
    when 'ContractorAssignment'
      "/projects/reviews"
    when 'Note'
      # Try to get parent URL
      if notifiable.notable_type == 'Lead'
        "/crm/leads/#{notifiable.notable_id}"
      elsif notifiable.notable_type == 'Deal'
        "/deals/#{notifiable.notable_id}"
      elsif notifiable.notable_type == 'Contact'
        "/contacts/#{notifiable.notable_id}"
      elsif notifiable.notable_type == 'Account'
        "/accounts/#{notifiable.notable_id}"
      end
    else
      nil
    end
  end
  
  # Compute action text if not explicitly set
  def computed_action_text
    return action_text if action_text.present?
    return nil unless notifiable.present?
    
    case notifiable_type
    when 'ServiceTicket'
      'View Ticket'
    when 'WarrantyClaim'
      'View Claim'
    when 'Lead'
      'View Lead'
    when 'Contact'
      'View Contact'
    when 'Account'
      'View Account'
    when 'Deal'
      'View Deal'
    when 'Quote'
      'View Quote'
    when 'Payment'
      'View Payment'
    when 'Invoice'
      'View Invoice'
    when 'Task'
      'View Task'
    when 'Communication'
      'View Message'
    when 'ContractorAssignment'
      'Review Now'
    when 'Note'
      'View Note'
    else
      'View Details'
    end
  end
  
  # Get actor display name
  def actor_name
    return nil unless actor.present?
    
    if actor.respond_to?(:name)
      actor.name
    elsif actor.respond_to?(:full_name)
      actor.full_name
    elsif actor.respond_to?(:email)
      actor.email
    else
      "User ##{actor_id}"
    end
  end
  
  # Get notifiable display name
  def notifiable_display
    return nil unless notifiable.present?
    
    if notifiable.respond_to?(:display_name)
      notifiable.display_name
    elsif notifiable.respond_to?(:name)
      notifiable.name
    elsif notifiable.respond_to?(:title)
      notifiable.title
    elsif notifiable.respond_to?(:subject)
      notifiable.subject
    else
      "#{notifiable_type} ##{notifiable_id}"
    end
  end
  
  # Time ago helper
  def time_ago
    seconds = Time.current - created_at
    
    if seconds < 60
      'Just now'
    elsif seconds < 3600
      "#{(seconds / 60).to_i}m ago"
    elsif seconds < 86400
      "#{(seconds / 3600).to_i}h ago"
    elsif seconds < 604800
      "#{(seconds / 86400).to_i}d ago"
    else
      "#{(seconds / 604800).to_i}w ago"
    end
  end
  
  # JSON representation with computed fields
  def as_json_with_details
    json = as_json(
      methods: [:computed_action_url, :computed_action_text, :actor_name, :notifiable_display, :time_ago],
      except: [:metadata, :action_data]
    )
    
    # Add attachment info if present
    if attachments.attached?
      json['attachments'] = attachments.map do |attachment|
        {
          id: attachment.id,
          filename: attachment.filename.to_s,
          content_type: attachment.content_type,
          byte_size: attachment.byte_size,
          # Use notification attachment download endpoint
          url: "/api/v1/notifications/#{id}/attachments/#{attachment.id}"
        }
      end
    end
    
    json
  end
end
