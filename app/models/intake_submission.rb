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
    
    # Extract location_id from submission data
    # Priority: explicit location_id (from location picker) > vehicle_location_id (from inventory embed)
    if submission_data['location_id'].present?
      lead_data[:location_id] = submission_data['location_id'].to_i
      Rails.logger.info "[IntakeSubmission] Assigning location_id from form picker: #{lead_data[:location_id]}"
    elsif submission_data['vehicle_location_id'].present?
      lead_data[:location_id] = submission_data['vehicle_location_id'].to_i
      Rails.logger.info "[IntakeSubmission] Assigning location_id from vehicle: #{lead_data[:location_id]}"
    end
    
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
    
    # Create note with vehicle information (if from inventory embed) and unmapped fields
    begin
      # Get notes from form field mapping (if any field was mapped to 'notes')
      form_mapped_notes = lead_data[:notes]
      
      # Build note content with vehicle info and/or unmapped data
      note_content = build_notes_with_vehicle(submission_data, unmapped_data, form, form_mapped_notes)
      
      if note_content.present?
        Note.create!(
          entity_type: 'lead',
          entity_id: new_lead.id,
          content: note_content,
          created_by_name: 'System (Intake Form)'
        )
        Rails.logger.info "Created note for lead #{new_lead.id} with form submission details"
      end
    rescue => note_error
      Rails.logger.error "Failed to create note for lead #{new_lead.id}: #{note_error.message}"
      # Don't fail the entire lead creation if note creation fails
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
    Rails.logger.info "[IntakeSubmission] >>> create_activity_and_notify called for lead #{lead.id}, form #{form.id}"
    return unless form.notified_user_id.present?
    
    notified_user = User.find_by(id: form.notified_user_id)
    Rails.logger.info "[IntakeSubmission] Notified user: #{notified_user&.email || 'NOT FOUND'} (ID: #{form.notified_user_id})"
    return unless notified_user
    
    # Create activity for the notified user
    activity = LeadActivity.create!(
      lead_id: lead.id,
      user_id: form.notified_user_id,
      assigned_to_id: form.notified_user_id,
      activity_type: 'reminder',
      subject: "New Lead from Intake Form: #{lead.first_name} #{lead.last_name}",
      description: "Lead captured via intake form '#{form.name}'. Contact: #{lead.email || lead.phone || 'N/A'}",
      priority: 'high',
      status: 'pending',
      reminder_time: Time.current,
      reminder_sent: false
    )
    
    # Send popup + bell notification (real-time toast in browser)
    ActivityReminderService.send_reminder(activity)
    
    # ALWAYS send email for new intake form leads, regardless of user notification preferences.
    # This is a direct lead notification — the dealer configured this person to receive it.
    send_intake_lead_email(lead, form, notified_user)
    
    Rails.logger.info "Created activity #{activity.id} and sent full notification for lead #{lead.id} to user #{notified_user.email}"
  rescue => e
    Rails.logger.error "Failed to create activity/notification for lead #{lead.id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
  
  def send_intake_lead_email(lead, form, user)
    return unless user.email.present?
    
    company = Company.find_by(id: form.company_id)
    submission_data = data || {}
    
    # Build vehicle info if from inventory embed
    vehicle_info = ""
    if submission_data['vehicle_title'].present?
      vehicle_info = "<br><br><strong>Home of Interest:</strong> #{submission_data['vehicle_title']}"
      vehicle_info += "<br>Price: $#{submission_data['vehicle_price']}" if submission_data['vehicle_price'].present?
      vehicle_info += "<br>Stock #: #{submission_data['vehicle_stock_number']}" if submission_data['vehicle_stock_number'].present?
      vehicle_info += "<br><a href='#{submission_data['vehicle_url']}'>View Listing</a>" if submission_data['vehicle_url'].present?
    end
    
    frontend_url = ENV['FRONTEND_URL'] || 'https://staging.crm.landlordinsight.com'
    
    subject = "New Lead: #{lead.first_name} #{lead.last_name} - #{form.name}"
    body = <<~HTML
      <h2>New Lead from Intake Form</h2>
      <p>A new lead has been captured via your intake form <strong>"#{form.name}"</strong>.</p>
      
      <h3>Contact Information</h3>
      <p>
        <strong>Name:</strong> #{lead.first_name} #{lead.last_name}<br>
        <strong>Email:</strong> #{lead.email || 'Not provided'}<br>
        <strong>Phone:</strong> #{lead.phone || 'Not provided'}
        #{vehicle_info}
      </p>
      
      <p><a href="#{frontend_url}/crm/leads/#{lead.id}" style="background-color: #3b82f6; color: white; padding: 12px 24px; text-decoration: none; border-radius: 5px; display: inline-block;">View Lead in CRM</a></p>
      
      <hr>
      <p style="color: #6b7280; font-size: 12px;">#{company&.name || 'RenterInsight'} - Automated Lead Notification</p>
    HTML
    
    begin
      CommunicationService.send_email(
        communicable: lead,
        to: user.email,
        subject: subject,
        body: body,
        category: 'system',
        content_type: 'text/html',
        skip_preference_check: true,
        metadata: {
          source: 'intake_form',
          form_id: form.id,
          form_name: form.name
        }
      )
      Rails.logger.info "[IntakeSubmission] \u2705 Sent intake lead email via CommunicationService to #{user.email}"
    rescue => e
      Rails.logger.error "[IntakeSubmission] \u274c Failed to send intake lead email: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end
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
  
  def build_notes_with_vehicle(submission_data, unmapped_data, form, form_mapped_notes = nil)
    notes = []
    
    # Check if this submission includes vehicle information (from inventory embed)
    vehicle_keys = %w[vehicle_id vehicle_title vehicle_year vehicle_make vehicle_model vehicle_vin vehicle_stock_number vehicle_price vehicle_url]
    has_vehicle_data = vehicle_keys.any? { |key| submission_data[key].present? }
    
    if has_vehicle_data
      notes << "🚗 VEHICLE OF INTEREST"
      notes << "=" * 50
      
      if submission_data['vehicle_title'].present?
        notes << "Vehicle: #{submission_data['vehicle_title']}"
      elsif submission_data['vehicle_year'].present? || submission_data['vehicle_make'].present? || submission_data['vehicle_model'].present?
        vehicle_desc = [submission_data['vehicle_year'], submission_data['vehicle_make'], submission_data['vehicle_model']].compact.join(' ')
        notes << "Vehicle: #{vehicle_desc}"
      end
      
      notes << "Stock #: #{submission_data['vehicle_stock_number']}" if submission_data['vehicle_stock_number'].present?
      notes << "VIN: #{submission_data['vehicle_vin']}" if submission_data['vehicle_vin'].present?
      notes << "Price: $#{submission_data['vehicle_price']}" if submission_data['vehicle_price'].present?
      notes << "Listing URL: #{submission_data['vehicle_url']}" if submission_data['vehicle_url'].present?
      notes << ""
    end
    
    # Add form submission details
    notes << "📋 FORM SUBMISSION"
    notes << "=" * 50
    notes << "Form: #{form.name}"
    notes << "Submitted: #{submitted_at || Time.current}"
    notes << ""
    
    # Add notes from form field mapping (if a field was mapped to 'notes')
    if form_mapped_notes.present?
      notes << "Customer Notes:"
      notes << form_mapped_notes
      notes << ""
    end
    
    # Add unmapped form data (if any)
    if unmapped_data.present?
      notes << "Additional Information:"
      unmapped_data.each do |key, value|
        next if value.blank?
        # Skip vehicle fields (already shown above)
        next if vehicle_keys.include?(key.to_s)
        # Skip internal/metadata fields
        next if %w[location_id source vehicle_location_id].include?(key.to_s)
        # Skip notes field (already shown above)
        next if key.to_s.downcase == 'notes' || key.to_s.downcase == 'comments' || key.to_s.downcase == 'message'
        
        formatted_key = key.to_s.humanize
        notes << "  #{formatted_key}: #{value}"
      end
    end
    
    notes.any? ? notes.join("\n") : nil
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
