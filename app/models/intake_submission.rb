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
    
    # Lead source resolution now lives in SourceResolverService — the exact
    # same 4-tier chain (explicit id → name/utm with fuzzy match → default →
    # "Web Form" fallback) is used here and on the partner API webhook path,
    # so a Zapier lead and an intake form lead attribute the same way.
    explicit_source_id = submission_data['source_id'] || submission_data['sourceId']
    utm_source_raw     = submission_data['utm_source'] || submission_data['utmSource']
    source_name        = utm_source_raw.present? ? utm_source_raw.to_s.tr('_', ' ').split.map(&:capitalize).join(' ') : nil

    resolved_source = SourceResolverService.resolve(
      company: Company.find_by(id: form.company_id),
      source_id: explicit_source_id,
      source_name: source_name,
      default_source_id: form.source_id
    )
    source_id = resolved_source&.id
    Rails.logger.info "[IntakeSubmission] Resolved source_id=#{source_id} (#{resolved_source&.name})" if resolved_source
    
    lead_data = { 
      company_id: form.company_id, 
      source_id: source_id, 
      status: 'new'
    }
    
    # Resolve location so a lead is NEVER orphaned (location-null leads are
    # invisible to location-scoped users). Priority:
    #   1. explicit location_id from the form's location picker
    #   2. location bound to the form itself (one-form-per-location setups)
    #   3. vehicle_location_id from an inventory embed
    #   4. company default location (safety net) so the lead stays visible
    if submission_data['location_id'].present?
      lead_data[:location_id] = submission_data['location_id'].to_i
      Rails.logger.info "[IntakeSubmission] Assigning location_id from form picker: #{lead_data[:location_id]}"
    elsif form.respond_to?(:location_id) && form.location_id.present?
      lead_data[:location_id] = form.location_id
      Rails.logger.info "[IntakeSubmission] Assigning location_id from form binding: #{lead_data[:location_id]}"
    elsif submission_data['vehicle_location_id'].present?
      lead_data[:location_id] = submission_data['vehicle_location_id'].to_i
      Rails.logger.info "[IntakeSubmission] Assigning location_id from vehicle: #{lead_data[:location_id]}"
    else
      fallback_location_id = company_default_location_id(form.company_id)
      if fallback_location_id.present?
        lead_data[:location_id] = fallback_location_id
        Rails.logger.info "[IntakeSubmission] No location resolved; using company default: #{fallback_location_id}"
      else
        Rails.logger.warn "[IntakeSubmission] No location resolved and no company default available; lead will be company-scoped only"
      end
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
      field_type = field['type'] || field[:type]
      lead_field = field['leadField'] || field[:leadField]
      lead_field_map = field['leadFieldMap'] || field[:leadFieldMap] || {}
      value = submission_data[field_name] || submission_data[field_name.to_sym]

      Rails.logger.info "[IntakeSubmission] Processing field: #{field_name}, type: #{field_type}, leadField: #{lead_field}, value: #{value.inspect}"

      # Address block: one form field, up to five sub-values, each mapped to
      # its own CRM Lead attribute. Sub-values that aren't mapped fall into
      # unmapped_data so they still show up in the lead's notes.
      if field_type == 'address' && value.is_a?(Hash)
        sub_values = value.transform_keys(&:to_s)
        lead_field_map.to_h.each do |sub_key, mapped_lead_field|
          next if mapped_lead_field.blank?
          sub_value = sub_values[sub_key.to_s]
          if sub_value.present?
            lead_data[mapped_lead_field.to_sym] = sub_value
            Rails.logger.info "[IntakeSubmission] Mapped #{field_name}.#{sub_key} -> #{mapped_lead_field} = #{sub_value}"
          end
        end
        # Any unmapped sub-values ride along in unmapped_data under a
        # namespaced key so they don't collide with other fields.
        sub_values.each do |sub_key, sub_value|
          next if sub_value.blank?
          next if lead_field_map[sub_key].present? || lead_field_map[sub_key.to_sym].present?
          unmapped_data["#{field_name}_#{sub_key}"] = sub_value
        end
      elsif lead_field.present? && value.present?
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

    # ── Duplicate resolution ─────────────────────────────────────────
    # Before creating a brand-new lead, check whether this person already
    # exists in the company across leads / contacts / accounts. We never drop
    # the inquiry — we either absorb it into the existing lead, or attach it as
    # a note to the existing contact/account/converted-lead and notify.
    company_obj = Company.find_by(id: form.company_id)
    resolver_match = nil
    if company_obj
      resolver_match = IdentityResolver.new(
        company_obj,
        email: lead_data[:email],
        phone: lead_data[:phone]
      ).resolve
    end

    if resolver_match
      Rails.logger.info "[IntakeSubmission] Identity match: #{resolver_match.type} ##{resolver_match.record.id} (converted=#{resolver_match.converted}, matched=#{resolver_match.matched})"

      if resolver_match.type == :lead && resolver_match.converted == false
        # CASE A: absorb into the existing (non-converted) lead.
        return absorb_into_existing_lead(resolver_match.record, lead_data, submission_data, unmapped_data, form)
      else
        # CASE B: existing contact / account / converted lead. Do NOT create a
        # new lead. Attach a note to that record and notify as an existing
        # customer inquiry.
        return attach_inquiry_to_existing(resolver_match, lead_data, submission_data, unmapped_data, form)
      end
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
  
  # CASE A: A non-converted lead already exists for this person. Absorb the
  # new submission into it instead of creating a duplicate. Fill only empty
  # fields (never overwrite good data), log the full submission as a note
  # (including any conflicting values), link this submission to that lead, and
  # notify the designated user that an EXISTING lead was updated.
  def absorb_into_existing_lead(existing_lead, lead_data, submission_data, unmapped_data, form)
    Rails.logger.info "[IntakeSubmission] Absorbing into existing lead ##{existing_lead.id} (fill-empty merge)"

    # Only consider real lead attributes for the merge; drop control keys.
    mergeable = lead_data.except(:company_id, :source_id, :status, :location_id, :owner_id)
    merge_result = MergeHelper.fill_empty(existing_lead, mergeable)
    existing_lead.save! if merge_result[:applied].any?

    # Point this submission at the existing lead. lead_created stays semantically
    # true (a lead exists for this submission), but we did not create a new one.
    update_columns(lead_id: existing_lead.id, lead_created: true)

    # Build the note: standard submission detail + any fill-empty conflicts.
    begin
      form_mapped_notes = lead_data[:notes]
      base_note = build_notes_with_vehicle(submission_data, unmapped_data, form, form_mapped_notes)
      conflict_block = MergeHelper.conflicts_note(merge_result[:conflicts])
      applied_block =
        if merge_result[:applied].any?
          "✅ FILLED EMPTY FIELDS FROM THIS SUBMISSION: " +
            merge_result[:applied].keys.map { |k| k.to_s.humanize }.join(', ')
        end

      note_content = [
        "🔁 REPEAT INQUIRY — absorbed into existing lead ##{existing_lead.id}",
        applied_block,
        conflict_block,
        base_note
      ].compact.join("\n\n")

      Note.create!(
        entity_type: 'lead',
        entity_id: existing_lead.id,
        content: note_content,
        created_by_name: 'System (Intake Form)'
      )
    rescue => note_error
      Rails.logger.error "[IntakeSubmission] Failed to write absorb note for lead #{existing_lead.id}: #{note_error.message}"
    end

    # Notify the designated user — as an UPDATE to an existing lead.
    create_activity_and_notify(existing_lead, form, mode: :existing_lead) if form.auto_create_activity

    existing_lead
  rescue => e
    Rails.logger.error "[IntakeSubmission] absorb_into_existing_lead failed: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    nil
  end

  # CASE B: The person already exists as a contact, account, or converted lead.
  # Do NOT create a new lead. Attach a note to that existing record capturing
  # the inquiry, and notify the designated user that an existing customer
  # reached out (wording differs from a brand-new lead).
  def attach_inquiry_to_existing(match, lead_data, submission_data, unmapped_data, form)
    record = match.record
    entity_label = case match.type
                   when :account then 'Account'
                   when :contact then 'Contact'
                   when :lead    then 'converted Lead'
                   end
    Rails.logger.info "[IntakeSubmission] Attaching inquiry to existing #{entity_label} ##{record.id}"

    # Note entity_type convention differs by record type in this app:
    #   leads  -> 'lead'   (lowercase, as used elsewhere here)
    #   others -> 'Contact' / 'Account' (capitalized, as used in their controllers)
    note_entity_type = case match.type
                       when :lead    then 'lead'
                       when :contact then 'Contact'
                       when :account then 'Account'
                       end

    # Fill-empty merge: enrich the matched record with any submission fields
    # it doesn't already have (never overwrite existing data). MergeHelper
    # only touches columns that actually exist on the record, so this is
    # safe across Contact/Account/Lead. Conflicts are captured for the note.
    mergeable = lead_data.except(:company_id, :source_id, :status, :location_id, :owner_id)
    merge_result = { applied: {}, conflicts: [] }
    begin
      merge_result = MergeHelper.fill_empty(record, mergeable)
      record.save! if merge_result[:applied].any?
    rescue => merge_error
      Rails.logger.error "[IntakeSubmission] Fill-empty merge failed on #{entity_label} #{record.id}: #{merge_error.message}"
    end

    begin
      form_mapped_notes = lead_data[:notes]
      base_note = build_notes_with_vehicle(submission_data, unmapped_data, form, form_mapped_notes)
      header = "👤 EXISTING CUSTOMER INQUIRY — already in system as #{entity_label} ##{record.id}. " \
               "New intake submission received; no new lead created."
      applied_block =
        if merge_result[:applied].any?
          "✅ FILLED EMPTY FIELDS FROM THIS SUBMISSION: " +
            merge_result[:applied].keys.map { |k| k.to_s.humanize }.join(', ')
        end
      conflict_block = MergeHelper.conflicts_note(merge_result[:conflicts])
      note_content = [header, applied_block, conflict_block, base_note].compact.join("\n\n")

      Note.create!(
        entity_type: note_entity_type,
        entity_id: record.id,
        content: note_content,
        created_by_name: 'System (Intake Form)'
      )
    rescue => note_error
      Rails.logger.error "[IntakeSubmission] Failed to write inquiry note for #{entity_label} #{record.id}: #{note_error.message}"
    end

    # This submission did not create a lead. Leave lead_id nil; mark handled.
    update_columns(lead_created: false)

    # Notify designated user that an EXISTING customer submitted the form.
    notify_existing_customer_inquiry(match, form) if form.auto_create_activity

    record
  rescue => e
    Rails.logger.error "[IntakeSubmission] attach_inquiry_to_existing failed: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    nil
  end

  # Notification for CASE B (existing contact/account/converted lead). Sends a
  # bell/email to the designated user, worded as an existing-customer inquiry
  # rather than a new lead. Links to the matched record's detail page.
  def notify_existing_customer_inquiry(match, form)
    record = match.record
    # Recipient priority: record.owner (the assigned rep) wins, then the form's
    # configured notified_user. This matches the product rule that inquiries
    # about an existing customer go to that customer's owner, not to whoever
    # happened to be listed on the form.
    notified_user =
      (record.respond_to?(:owner) ? record.owner : nil) ||
      (form.notified_user_id.present? ? User.find_by(id: form.notified_user_id) : nil)
    return unless notified_user

    person_name = match.name.presence || 'Existing customer'
    entity_label = case match.type
                   when :account then 'Account'
                   when :contact then 'Contact'
                   else 'Customer'
                   end

    # Bell/popup activity is attached to a lead in this system; for non-lead
    # records we skip the LeadActivity row and send the email notification,
    # which is the channel that must always fire per product requirement.
    begin
      send_existing_customer_email(match, form, notified_user, person_name, entity_label)
    rescue => e
      Rails.logger.error "[IntakeSubmission] existing-customer notify failed: #{e.message}"
    end
  end

  # Email variant for CASE B — "existing customer submitted your form".
  def send_existing_customer_email(match, form, user, person_name, entity_label)
    return unless user.email.present?

    company = Company.find_by(id: form.company_id)
    record = match.record
    frontend_url = ENV['FRONTEND_URL'] || 'https://staging.crm.landlordinsight.com'
    detail_path = case match.type
                  when :account then "/accounts/#{record.id}"
                  when :contact then "/contacts/#{record.id}"
                  when :lead    then "/crm/leads/#{record.id}"
                  else "/"
                  end

    subject = "Existing customer inquiry: #{person_name} - #{form.name}"
    body = <<~HTML
      <h2>Existing Customer Submitted Your Intake Form</h2>
      <p><strong>#{person_name}</strong> submitted your intake form <strong>"#{form.name}"</strong>.</p>
      <p>This person is <strong>already in your system</strong> as a #{entity_label} (##{record.id}), so no new lead was created. The inquiry has been logged as a note on their record.</p>

      <h3>Contact Information</h3>
      <p>
        <strong>Name:</strong> #{person_name}<br>
        <strong>Email:</strong> #{record.try(:email) || 'Not provided'}<br>
        <strong>Phone:</strong> #{record.try(:phone) || 'Not provided'}
      </p>

      <p><a href="#{frontend_url}#{detail_path}" style="background-color: #3b82f6; color: white; padding: 12px 24px; text-decoration: none; border-radius: 5px; display: inline-block;">View #{entity_label} in CRM</a></p>

      <hr>
      <p style="color: #6b7280; font-size: 12px;">#{company&.name || 'RenterInsight'} - Automated Notification</p>
    HTML

    # Attach the Communication row to the recipient rep, not to the customer
    # record. This is a system-to-rep ping ("hey, look at this incoming"), not
    # part of the customer's conversation — putting it on the customer's
    # timeline was confusing (looked like a failed email TO the customer).
    #
    # Deliberately does NOT pass `user:`. This is a platform-generated
    # notification TO a rep, not correspondence FROM one, so the sender must
    # resolve Location → Company → Platform. Passing the recipient here made
    # the user tier fire, which meant the From address swung around based on
    # whether that rep happened to have a personal mailbox connected — and
    # when they didn't, it fell to whichever individual's mailbox was wired
    # into the company config. See send_intake_lead_email for the same rule.
    CommunicationService.send_email(
      communicable: user,
      to: user.email,
      subject: subject,
      body: body,
      category: 'system',
      content_type: 'text/html',
      skip_preference_check: true,
      metadata: {
        source: 'intake_form_existing_customer',
        form_id: form.id,
        form_name: form.name,
        matched_entity_type: match.type.to_s,
        matched_entity_id: record.id
      }
    )
    Rails.logger.info "[IntakeSubmission] ✅ Sent existing-customer inquiry email to #{user.email} (company/platform sender)"
  end

  def create_activity_and_notify(lead, form, mode: :new_lead)
    Rails.logger.info "[IntakeSubmission] >>> create_activity_and_notify called for lead #{lead.id}, form #{form.id}"
    return unless form.notified_user_id.present?
    
    notified_user = User.find_by(id: form.notified_user_id)
    Rails.logger.info "[IntakeSubmission] Notified user: #{notified_user&.email || 'NOT FOUND'} (ID: #{form.notified_user_id})"
    return unless notified_user

    is_update = (mode == :existing_lead)
    subject_prefix = is_update ? 'Repeat Inquiry on Existing Lead' : 'New Lead from Intake Form'
    description_prefix = is_update ? 'Existing lead re-submitted intake form' : 'Lead captured via intake form'

    # Create activity for the notified user
    activity = LeadActivity.create!(
      lead_id: lead.id,
      user_id: form.notified_user_id,
      assigned_to_id: form.notified_user_id,
      activity_type: 'reminder',
      subject: "#{subject_prefix}: #{lead.first_name} #{lead.last_name}",
      description: "#{description_prefix} '#{form.name}'. Contact: #{lead.email || lead.phone || 'N/A'}",
      priority: 'high',
      status: 'pending',
      reminder_time: Time.current,
      reminder_sent: false
    )
    
    # Send popup + bell notification (real-time toast in browser)
    ActivityReminderService.send_reminder(activity)
    
    # ALWAYS send email for intake form leads, regardless of user notification
    # preferences. This is a direct lead notification the dealer configured.
    send_intake_lead_email(lead, form, notified_user, is_update: is_update)
    
    Rails.logger.info "Created activity #{activity.id} and sent full notification for lead #{lead.id} to user #{notified_user.email}"
  rescue => e
    Rails.logger.error "Failed to create activity/notification for lead #{lead.id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
  
  def send_intake_lead_email(lead, form, user, is_update: false)
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

    heading = is_update ? 'Repeat Inquiry on Existing Lead' : 'New Lead from Intake Form'
    subject = if is_update
                "Repeat Inquiry: #{lead.first_name} #{lead.last_name} - #{form.name}"
              else
                "New Lead: #{lead.first_name} #{lead.last_name} - #{form.name}"
              end
    intro = if is_update
              "An <strong>existing lead</strong> re-submitted your intake form <strong>\"#{form.name}\"</strong>. We filled in any missing details and logged the new submission as a note — no duplicate lead was created."
            else
              "A new lead has been captured via your intake form <strong>\"#{form.name}\"</strong>."
            end

    body = <<~HTML
      <h2>#{heading}</h2>
      <p>#{intro}</p>
      
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
      # Deliberately does NOT pass `user:`. Sender resolves Location \u2192 Company
      # \u2192 Platform only; the assigned rep decides WHO gets told about the lead,
      # never who the mail comes FROM. Routing this through the user tier meant
      # the From address depended on whether the assigned rep had a personal
      # mailbox connected, and when they didn't it fell through to whatever
      # individual mailbox was wired into the company config \u2014 so reps received
      # lead alerts that appeared to be sent by a coworker.
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
          form_name: form.name,
          existing_lead_update: is_update
        }
      )
      Rails.logger.info "[IntakeSubmission] \u2705 Sent intake lead email via CommunicationService to #{user.email}"
    rescue => e
      Rails.logger.error "[IntakeSubmission] \u274c Failed to send intake lead email: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end
  end
  
  private
  
  # Deterministic fallback location for a company so intake leads are never
  # orphaned (a null location_id hides the lead from location-scoped users).
  # Prefers the Corporate location, then the first active location by id.
  def company_default_location_id(company_id)
    company = Company.find_by(id: company_id)
    return nil unless company
    
    corporate = company.locations.corporate.active.order(:id).first
    return corporate.id if corporate
    
    company.locations.active.order(:id).first&.id
  rescue => e
    Rails.logger.error "[IntakeSubmission] company_default_location_id failed: #{e.message}"
    nil
  end
  
  # NOTE: broadcast_new_lead_notification was removed. It fanned every intake
  # lead out to a hardcoded "lead_notifications_1" stream plus a company-wide
  # stream, which would have shown one dealer's lead to every user at that
  # company. It was never wired to a caller, so it never fired in production.
  # Intake notification targeting is single-recipient by design: the form's
  # notified_user gets the LeadActivity, the bell/popup (via
  # ActivityReminderService, which resolves activity.assigned_to) and the
  # email. Do not reintroduce a broadcast here.

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
        next if %w[location_id source source_id sourceId utm_source utmSource vehicle_location_id].include?(key.to_s)
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
