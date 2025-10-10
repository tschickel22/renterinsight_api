class IntakeSubmission < ApplicationRecord
  belongs_to :intake_form
  belongs_to :lead, optional: true
  
  # 'data' column is already JSON type, no need to serialize
  # Just use accessor methods for compatibility
  
  # Alias for compatibility
  def payload
    data
  end
  
  def payload=(value)
    self.data = value
  end
  
  before_create :set_submitted_at
  after_create :create_lead_from_submission
  after_create :increment_form_count
  
  scope :recent, -> { order(submitted_at: :desc) }
  scope :with_leads, -> { where(lead_created: true) }
  scope :without_leads, -> { where(lead_created: false) }
  
  def create_lead_from_submission
    return if lead_created? || lead.present?
    
    form = intake_form
    submission_data = data || {}
    
    # Map common field variations
    first_name = extract_field(submission_data, ['firstName', 'first_name', 'firstname', 'fname', 'name'])
    last_name = extract_field(submission_data, ['lastName', 'last_name', 'lastname', 'lname'])
    email = extract_field(submission_data, ['email', 'emailAddress', 'email_address', 'contact_email'])
    phone = extract_field(submission_data, ['phone', 'phoneNumber', 'phone_number', 'telephone', 'mobile'])
    
    # If we only have a single 'name' field, try to split it
    if first_name && !last_name && first_name.include?(' ')
      parts = first_name.split(' ', 2)
      first_name = parts[0]
      last_name = parts[1]
    end
    
    # Build notes from all form data
    notes = build_notes(submission_data, form)
    
    # Skip if no contact info
    return unless email.present? || phone.present? || first_name.present?
    
    lead_data = {
      company_id: form.company_id,
      source_id: form.source_id,
      first_name: first_name,
      last_name: last_name,
      email: email,
      phone: phone,
      notes: notes,
      status: 'new'
    }
    
    new_lead = Lead.create!(lead_data)
    update_columns(lead_id: new_lead.id, lead_created: true)
    
    Rails.logger.info "Created lead #{new_lead.id} from intake submission #{id}"
    
    # Broadcast notification to all users in the company
    broadcast_new_lead_notification(new_lead, form)
    
    new_lead
  rescue => e
    Rails.logger.error "Failed to create lead from submission #{id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    nil
  end
  
  private
  
  def broadcast_new_lead_notification(lead, form)
    # Get all active users in the company who should receive notifications
    company = Company.find(form.company_id)
    
    # Broadcast notification data
    notification_data = {
      type: 'new_lead',
      lead_id: lead.id,
      lead_name: "#{lead.first_name} #{lead.last_name}".strip.presence || 'New Lead',
      lead_email: lead.email,
      lead_phone: lead.phone,
      form_name: form.name,
      form_id: form.id,
      created_at: Time.current.iso8601
    }
    
    # Broadcast to all users (matching the frontend subscription)
    # The frontend subscribes with user_id parameter
    # For testing, broadcast to user 1 which matches the frontend
    ActionCable.server.broadcast(
      "lead_notifications_1",
      notification_data
    )
    
    # Also broadcast to company channel for future multi-user support
    ActionCable.server.broadcast(
      "lead_notifications_company_#{company.id}",
      notification_data
    )
    
    Rails.logger.info "Broadcasted new lead notification for lead #{lead.id} to channels: lead_notifications_1, lead_notifications_company_#{company.id}"
  rescue => e
    Rails.logger.error "Failed to broadcast lead notification: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
  
  def extract_field(data, possible_keys)
    possible_keys.each do |key|
      value = data[key] || data[key.to_s]
      return value if value.present?
    end
    nil
  end
  
  def build_notes(submission_data, form)
    notes = ["Submitted via intake form: #{form.name}"]
    notes << "Form ID: #{form.id}"
    notes << "Submission Time: #{submitted_at || Time.current}"
    notes << ""
    notes << "Form Data:"
    
    # Add all form fields to notes
    submission_data.each do |key, value|
      next if value.blank?
      # Format the key nicely
      formatted_key = key.to_s.humanize
      notes << "#{formatted_key}: #{value}"
    end
    
    notes.join("\n")
  end
  
  def set_submitted_at
    self.submitted_at ||= Time.current
  end
  
  def increment_form_count
    intake_form&.increment_submission_count!
  end
end
