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
    return unless form.auto_create_lead  # Skip if auto-create is disabled
    
    submission_data = data || {}
    
    # Use explicit field mappings if available
    field_mappings = form.field_mappings || {}
    
    # Get or create default "Web Form" source if form doesn't have one
    source_id = form.source_id
    if source_id.nil?
      default_source = Source.find_or_create_by(
        company_id: form.company_id,
        name: 'Web Form'
      ) do |s|
        s.is_active = true
        s.description = 'Leads captured via intake forms'
      end
      source_id = default_source.id
      Rails.logger.info "[IntakeSubmission] Using default Web Form source: #{source_id}"
    end
    
    lead_data = { 
      company_id: form.company_id, 
      source_id: source_id, 
      status: 'new'
    }
    
    # Only set owner_id if notified_user exists
    if form.notified_user_id.present?
      lead_data[:owner_id] = form.notified_user_id
    end
    
    unmapped_data = {}
    
    Rails.logger.info "[IntakeSubmission] Form fields: #{form.fields.inspect}"
    Rails.logger.info "[IntakeSubmission] Submission data: #{submission_data.inspect}"
    
    # Map fields using explicit mappings
    form.fields.each do |field|
      field_name = field['name'] || field[:name]
      lead_field = field['leadField'] || field[:leadField]
      value = submission_data[field_name] || submission_data[field_name.to_sym]
      
      Rails.logger.info "[IntakeSubmission] Processing field: #{field_name}, leadField: #{lead_field}, value: #{value}"
      
      if lead_field.present? && value.present?
        lead_data[lead_field.to_sym] = value
        Rails.logger.info "[IntakeSubmission] Mapped #{field_name} -> #{lead_field} = #{value}"
      elsif value.present?
        unmapped_data[field_name] = value
      end
    end
    
    # Smart field detection: If no explicit mappings found contact info,
    # try to auto-detect from common field naming patterns
    if lead_data[:email].blank? && lead_data[:phone].blank? && lead_data[:first_name].blank?
      Rails.logger.info "[IntakeSubmission] No contact info from mappings, trying smart detection..."
      
      submission_data.each do |key, value|
        next if value.blank?
        key_lower = key.to_s.downcase
        
        # Email detection
        if lead_data[:email].blank? && (key_lower.include?('email') || value.to_s.match?(/\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i))
          lead_data[:email] = value
          Rails.logger.info "[IntakeSubmission] Auto-detected email: #{value}"
        end
        
        # Phone detection
        if lead_data[:phone].blank? && (key_lower.include?('phone') || key_lower.include?('mobile') || key_lower.include?('cell'))
          lead_data[:phone] = value
          Rails.logger.info "[IntakeSubmission] Auto-detected phone: #{value}"
        end
        
        # First name detection
        if lead_data[:first_name].blank? && (key_lower == 'first_name' || key_lower == 'firstname' || key_lower == 'first')
          lead_data[:first_name] = value
          Rails.logger.info "[IntakeSubmission] Auto-detected first_name: #{value}"
        end
        
        # Last name detection
        if lead_data[:last_name].blank? && (key_lower == 'last_name' || key_lower == 'lastname' || key_lower == 'last')
          lead_data[:last_name] = value
          Rails.logger.info "[IntakeSubmission] Auto-detected last_name: #{value}"
        end
        
        # Full name detection (split into first/last)
        if lead_data[:first_name].blank? && (key_lower == 'name' || key_lower == 'full_name' || key_lower == 'fullname')
          parts = value.to_s.split(' ', 2)
          lead_data[:first_name] = parts[0] if parts[0].present?
          lead_data[:last_name] = parts[1] if parts[1].present?
          Rails.logger.info "[IntakeSubmission] Auto-detected name: first=#{parts[0]}, last=#{parts[1]}"
        end
      end
    end
    
    Rails.logger.info "[IntakeSubmission] Final lead_data before validation: #{lead_data.inspect}"
    
    # Skip if no contact info
    unless lead_data[:email].present? || lead_data[:phone].present? || lead_data[:first_name].present?
      Rails.logger.warn "[IntakeSubmission] Skipping lead creation - no contact info found"
      return
    end
    
    Rails.logger.info "[IntakeSubmission] Creating lead with data: #{lead_data.inspect}"
    new_lead = Lead.create!(lead_data)
    Rails.logger.info "[IntakeSubmission] Lead created successfully: #{new_lead.id}"
    
    update_columns(lead_id: new_lead.id, lead_created: true)
    
    Rails.logger.info "Created lead #{new_lead.id} from intake submission #{id}"
    
    # Create note with unmapped fields (using Note model, not lead.notes column)
    if unmapped_data.present?
      begin
        note_content = build_notes(unmapped_data, form)
        Note.create!(
          entity_type: 'lead',
          entity_id: new_lead.id,
          content: note_content,
          created_by_name: 'System (Intake Form)'
        )
        Rails.logger.info "Created note for lead #{new_lead.id} with unmapped form data"
      rescue => note_error
        Rails.logger.error "Failed to create note for lead #{new_lead.id}: #{note_error.message}"
        # Don't fail the entire lead creation if note creation fails
      end
    end
    
    # Create activity and send notification if enabled
    create_activity_and_notify(new_lead, form) if form.auto_create_activity
    
    new_lead
  rescue => e
    Rails.logger.error "Failed to create lead from submission #{id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    nil
  end
  
  def create_activity_and_notify(lead, form)
    return unless form.notified_user_id.present?
    
    # Create activity for the notified user
    activity = LeadActivity.create!(
      lead_id: lead.id,
      user_id: form.notified_user_id,
      activity_type: 'reminder',
      subject: "New Lead from Intake Form: #{lead.first_name} #{lead.last_name}",
      description: "Lead captured via intake form '#{form.name}'. Contact: #{lead.email || lead.phone || 'N/A'}",
      priority: 'high',
      status: 'pending',
      reminder_time: Time.current,  # Fixed: use reminder_time instead of due_at
      reminder_sent: false
    )
    
    # Send immediate popup notification
    ActivityReminderService.send_popup_notification(activity)
    
    Rails.logger.info "Created activity #{activity.id} and sent notification for lead #{lead.id}"
  rescue => e
    Rails.logger.error "Failed to create activity/notification for lead #{lead.id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
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
