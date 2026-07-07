# frozen_string_literal: true

# Job to process nurture sequence steps for ANY enrolled entity (Lead, Contact, Account, Deal)
# POLYMORPHIC: Works with enrollment.enrollable instead of enrollment.lead
class ProcessNurtureStepJob < ApplicationJob
  queue_as :default
  
  # Retry with exponential backoff for transient failures
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(enrollment_id)
    enrollment = NurtureEnrollment.find_by(id: enrollment_id)
    return unless enrollment&.status == 'running'

    sequence = enrollment.nurture_sequence
    return unless sequence&.is_active

    # Get current step
    current_index = enrollment.current_step_index || 0
    steps = sequence.nurture_steps.order(:position)
    current_step = steps[current_index]

    return unless current_step

    # POLYMORPHIC: Get the enrolled entity (Lead, Contact, Account, Deal, etc.)
    entity = enrollment.enrollable
    return unless entity

    entity_type = entity.class.name  # "Lead", "Contact", etc.
    Rails.logger.info "[Nurture] Processing #{entity_type} #{entity.id}, step #{current_index + 1}/#{steps.count}"

    # Process the step based on type
    Rails.logger.info "[Nurture] Processing step type: #{current_step.step_type} (step_id: #{current_step.id})"
    
    case current_step.step_type
    when 'email'
      send_nurture_email(entity, current_step, enrollment)
    when 'sms'
      send_nurture_sms(entity, current_step, enrollment)
    when 'wait'
      # Wait steps are handled by scheduling
      Rails.logger.info "[Nurture] Wait step #{current_step.id} - waiting #{current_step.wait_days} days"
    when 'task'
      # Create a task/activity for the entity
      Rails.logger.info "[Nurture] Creating task for step #{current_step.id}"
      create_task_activity(entity, current_step)
    when 'call'
      # Legacy: treat call steps as task creation
      Rails.logger.info "[Nurture] Creating call task for step #{current_step.id}"
      create_call_reminder(entity, current_step)
    else
      Rails.logger.warn "[Nurture] Unknown step type: #{current_step.step_type}"
    end

    # Move to next step
    next_index = current_index + 1
    if next_index < steps.count
      enrollment.update!(current_step_index: next_index)
      
      # Schedule next step
      next_step = steps[next_index]
      wait_days = next_step.wait_days || 0
      ProcessNurtureStepJob.set(wait: wait_days.days).perform_later(enrollment.id)
    else
      # Sequence completed
      enrollment.update!(status: 'completed')
      Rails.logger.info "[Nurture] Enrollment #{enrollment.id} completed"
    end
  rescue => e
    Rails.logger.error "[Nurture] Error processing enrollment #{enrollment_id}: #{e.message}\n#{e.backtrace.join("\n")}"
    # Don't re-raise - let retry logic handle it
  end

  private

  def send_nurture_email(entity, step, enrollment)
    # POLYMORPHIC: Get email from any entity type
    email = entity.email
    return unless email.present?

    # Build context for merge field rendering - works for any entity
    context = build_merge_context(entity)

    # Render template if present, otherwise use step content with merge fields
    subject, body = render_content(step, context, entity)

    # Process attachments: tracked links append to body, inline files load into upload
    company = entity.respond_to?(:company) ? entity.company : nil
    tracked_link_records, inline_uploads, attachment_metadata =
      process_step_attachments(step, entity, company)
    body = append_tracked_link_section(body, tracked_link_records) if tracked_link_records.any?

    # Inject inventory block when the step opts in. The matcher waterfalls
    # (preferred → click-inferred → criteria → rotation); on no match we
    # silently skip so the email still goes out.
    inventory_meta = nil
    inventory_inline_images = []
    if step.include_inventory && company
      begin
        matcher  = InventoryMatcherService.new(
          entity,
          company,
          filters: {
            statuses:       Array(step.try(:inventory_statuses)),
            require_images: step.try(:inventory_require_images),
          }
        )
        vehicles = matcher.match
        if vehicles.present?
          block_builder = InventoryEmailBlockBuilder.new(
            company:     company,
            entity:      entity,
            vehicles:    vehicles,
            source_type: 'NurtureStep',
            source_id:   step.id
          )
          body += block_builder.build_html
          inventory_inline_images = block_builder.inline_images
          inventory_meta = {
            inventory_vehicles: vehicles.map { |v|
              { id: v.id, name: [v.year, v.make, v.model].compact.join(' ') }
            },
            inventory_match_mode: matcher.match_mode,
            inventory_tracked_link_ids: block_builder.tracked_link_ids
          }
        end
      rescue => e
        Rails.logger.error "[Nurture] Inventory injection failed for step #{step.id}: #{e.message}"
      end
    end

    Rails.logger.info "[Nurture] Sending email to #{email} for #{entity.class.name} #{entity.id}, step #{step.id}"

    metadata_hash = {
      nurture_step_id: step.id,
      nurture_sequence_id: step.nurture_sequence_id,
      nurture_enrollment_id: enrollment.id,
      step_type: 'email',
      step_position: step.position,
      attachments: attachment_metadata
    }
    metadata_hash.merge!(inventory_meta) if inventory_meta

    # Use CommunicationService - it handles:
    # - User-level Outlook/Gmail OAuth (if the sending user has a verified
    #   connection, this wins over location/company/platform config)
    # - Waterfall settings (Location → Company → Platform)
    # - Provider selection (SMTP/SendGrid)
    # - Actual sending via configured provider
    # - Communication record creation with proper metadata
    #
    # Sending user resolution: prefer the lead/contact owner so the email
    # comes from the rep who owns the relationship (their Outlook connection
    # if set up, otherwise their address at the company sender). Falls back
    # to nil (platform waterfall) when the entity has no owner.
    sending_user = entity.respond_to?(:owner) ? entity.owner : nil

    result = CommunicationService.send_email(
      communicable: entity,
      to: email,
      subject: subject,
      body: body,
      category: 'nurture',
      user: sending_user,
      attachments: inline_uploads,
      inline_images: inventory_inline_images,
      metadata: metadata_hash.deep_stringify_keys,
      skip_preference_check: false # Respect user email preferences
    )

    # Backfill communication_id on tracked links once the Communication exists
    if result[:success] && result[:communication].present?
      tracked_link_records.each do |tl|
        tl.update_columns(communication_id: result[:communication].id) rescue nil
      end

      inv_link_ids = inventory_meta&.dig(:inventory_tracked_link_ids) || []
      if inv_link_ids.any?
        TrackedLink.where(id: inv_link_ids).update_all(communication_id: result[:communication].id)
      end
    end

    # Clean up any tempfiles created for inline attachments
    inline_uploads.each do |u|
      tmp = u.respond_to?(:tempfile) ? u.tempfile : nil
      begin
        tmp&.close
        tmp&.unlink
      rescue StandardError
        nil
      end
    end

    if result[:success]
      Rails.logger.info "[Nurture] ✅ Email sent successfully (comm_id: #{result[:communication].id}, external_id: #{result[:external_id]})"
    else
      Rails.logger.error "[Nurture] ❌ Email failed: #{result[:error]}"
      raise StandardError, "Email delivery failed: #{result[:error]}" # Trigger retry
    end
  rescue CommunicationService::OptOutError => e
    Rails.logger.warn "[Nurture] #{entity.class.name} #{entity.id} has opted out of email: #{e.message}"
    # Don't raise - user has opted out, continue sequence
  rescue => e
    Rails.logger.error "[Nurture] Email error for step #{step.id}: #{e.message}"
    raise # Re-raise to trigger job retry
  end

  def send_nurture_sms(entity, step, enrollment)
    # POLYMORPHIC: Get phone from any entity type
    phone = entity.phone
    return unless phone.present?

    # Build context for merge field rendering - works for any entity
    context = build_merge_context(entity)

    # Render template if present, otherwise use step content with merge fields
    _, body = render_content(step, context, entity)  # SMS only needs body

    Rails.logger.info "[Nurture] Sending SMS to #{phone} for #{entity.class.name} #{entity.id}, step #{step.id}"

    # Use CommunicationService - it handles:
    # - Waterfall settings (Location → Company → Platform)
    # - Twilio configuration
    # - Actual sending via Twilio API
    # - Communication record creation with proper metadata
    result = CommunicationService.send_sms(
      communicable: entity,
      to: phone,
      body: body,
      category: 'nurture',
      metadata: {
        nurture_step_id: step.id,
        nurture_sequence_id: step.nurture_sequence_id,
        nurture_enrollment_id: enrollment.id,
        step_type: 'sms',
        step_position: step.position
      },
      skip_preference_check: false # Respect user SMS preferences
    )

    if result[:success]
      Rails.logger.info "[Nurture] ✅ SMS sent successfully (comm_id: #{result[:communication].id}, external_id: #{result[:external_id]})"
    else
      Rails.logger.error "[Nurture] ❌ SMS failed: #{result[:error]}"
      raise StandardError, "SMS delivery failed: #{result[:error]}" # Trigger retry
    end
  rescue CommunicationService::OptOutError => e
    Rails.logger.warn "[Nurture] #{entity.class.name} #{entity.id} has opted out of SMS: #{e.message}"
    # Don't raise - user has opted out, continue sequence
  rescue => e
    Rails.logger.error "[Nurture] SMS error for step #{step.id}: #{e.message}"
    raise # Re-raise to trigger job retry
  end

  def create_call_reminder(entity, step)
    # POLYMORPHIC: Create activity for any entity type
    entity_type = entity.class.name
    
    case entity_type
    when 'Lead'
      create_lead_call_activity(entity, step)
    when 'Contact'
      create_contact_call_activity(entity, step)
    else
      Rails.logger.warn "[Nurture] Call reminder step skipped for #{entity_type} (not yet supported)"
    end
  end

  def create_lead_call_activity(lead, step)
    # Assign to lead owner or first active user
    user = lead.owner || lead.company.users.where(status: 'active').first
    return unless user

    # Calculate due date based on wait_days
    due_date = Time.current + ((step.wait_days || 0) > 0 ? step.wait_days.days : 1.hour)
    reminder_time = Time.current

    LeadActivity.create!(
      lead: lead,
      user: user,
      assigned_to: user,
      activity_type: 'call',
      subject: "Nurture Call: #{lead.first_name} #{lead.last_name}",
      description: step.body.presence || 'Follow up call from nurture sequence',
      status: 'pending',
      priority: 'medium',
      due_date: due_date,
      phone_number: lead.phone,
      call_direction: 'outbound',
      reminder_time: reminder_time,
      reminder_method: ['popup'],
      reminder_sent: false,
      metadata: {
        nurture_step_id: step.id,
        nurture_sequence_id: step.nurture_sequence_id,
        source: 'nurture_sequence'
      }
    )

    Rails.logger.info "[Nurture] ✅ Call activity created for Lead #{lead.id}"
  rescue => e
    Rails.logger.error "[Nurture] Failed to create lead call activity: #{e.message}"
  end

  def create_contact_call_activity(contact, step)
    # Assign to contact owner or first active user
    user = contact.owner || contact.company.users.where(status: 'active').first
    return unless user

    # Calculate due date based on wait_days
    due_date = Time.current + ((step.wait_days || 0) > 0 ? step.wait_days.days : 1.hour)
    reminder_time = Time.current

    ContactActivity.create!(
      contact: contact,
      user: user,
      assigned_to: user,
      activity_type: 'call',
      subject: "Nurture Call: #{contact.first_name} #{contact.last_name}",
      description: step.body.presence || 'Follow up call from nurture sequence',
      status: 'pending',
      priority: 'medium',
      due_date: due_date,
      phone_number: contact.phone,
      call_direction: 'outbound',
      reminder_time: reminder_time,
      reminder_method: ['popup'],
      reminder_sent: false,
      metadata: {
        nurture_step_id: step.id,
        nurture_sequence_id: step.nurture_sequence_id,
        source: 'nurture_sequence'
      }
    )

    Rails.logger.info "[Nurture] ✅ Call activity created for Contact #{contact.id}"
  rescue => e
    Rails.logger.error "[Nurture] Failed to create contact call activity: #{e.message}"
  end

  # ---- Task step: create a task activity on the entity ----

  def create_task_activity(entity, step)
    entity_type = entity.class.name
    user = entity.respond_to?(:owner) ? entity.owner : nil
    user ||= entity.company.users.where(status: 'active').first if entity.respond_to?(:company)
    unless user
      Rails.logger.warn "[Nurture] No user found for task assignment on #{entity_type} #{entity.id}"
      return
    end

    due_date = Time.current + ((step.wait_days || 0) > 0 ? step.wait_days.days : 1.hour)
    subject = step.subject.presence || step.body.presence || "Nurture Task: #{entity_name(entity)}"
    description = step.body.presence || 'Task created by nurture sequence'

    task_attrs = {
      user: user,
      assigned_to: user,
      activity_type: 'task',
      subject: subject,
      description: description,
      status: 'pending',
      priority: 'medium',
      due_date: due_date,
      reminder_time: Time.current,
      reminder_method: ['popup'],
      reminder_sent: false,
      metadata: {
        nurture_step_id: step.id,
        nurture_sequence_id: step.nurture_sequence_id,
        source: 'nurture_sequence'
      }
    }

    case entity_type
    when 'Lead'
      LeadActivity.create!(task_attrs.merge(lead: entity))
    when 'Contact'
      ContactActivity.create!(task_attrs.merge(contact: entity))
    when 'Account'
      AccountActivity.create!(task_attrs.merge(account: entity))
    when 'Deal'
      DealActivity.create!(task_attrs.merge(deal: entity))
    else
      Rails.logger.warn "[Nurture] Task creation not supported for #{entity_type}"
      return
    end

    Rails.logger.info "[Nurture] ✅ Task activity created for #{entity_type} #{entity.id}: #{subject}"
  rescue => e
    Rails.logger.error "[Nurture] Failed to create task activity for #{entity.class.name} #{entity.id}: #{e.message}"
  end

  def entity_name(entity)
    if entity.respond_to?(:first_name)
      "#{entity.first_name} #{entity.last_name}".strip
    elsif entity.respond_to?(:name)
      entity.name
    else
      "#{entity.class.name} #{entity.id}"
    end
  end

  # Build merge field context from any entity
  def build_merge_context(entity)
    context = {}
    
    # Common fields that most entities have
    context[:first_name] = entity.first_name if entity.respond_to?(:first_name)
    context[:last_name] = entity.last_name if entity.respond_to?(:last_name)
    context[:recipient_name] = "#{context[:first_name]} #{context[:last_name]}".strip if context[:first_name]
    context[:email] = entity.email if entity.respond_to?(:email)
    context[:phone] = entity.phone if entity.respond_to?(:phone)
    context[:company_name] = entity.company&.name if entity.respond_to?(:company)
    context[:location_name] = entity.location&.name if entity.respond_to?(:location)
    
    # Entity-specific fields
    case entity.class.name
    when 'Lead'
      context[:lead_source] = entity.source if entity.respond_to?(:source)
      context[:lead_status] = entity.status if entity.respond_to?(:status)
    when 'Contact'
      context[:job_title] = entity.title if entity.respond_to?(:title)
      context[:department] = entity.department if entity.respond_to?(:department)
      context[:account_name] = entity.account&.name if entity.respond_to?(:account)
    end
    
    context
  end

  # Render content with template or merge fields
  # Template types that are system-transactional (invitations, warranty
  # status alerts, etc.) and must NEVER render inside a nurture sequence.
  # Guardrail against a misconfigured step referencing an unrelated template
  # from the general template picker — that's exactly how a nurture step
  # ended up sending a "You're Invited to Join…" portal invitation email.
  FORBIDDEN_TEMPLATE_TYPES = %w[
    company_user_invitation
    portal_user_invitation
    tenant_invitation
    warranty_approved_client
    warranty_denied_client
    warranty_submitted_to_manufacturer
    warranty_manufacturer_responded
  ].freeze

  def render_content(step, context, entity)
    if step.template_id.present?
      template = CommunicationTemplate.find_by(id: step.template_id)
      if template && FORBIDDEN_TEMPLATE_TYPES.include?(template.template_type.to_s)
        Rails.logger.warn "[Nurture] Refusing to render forbidden template " \
                          "#{template.id} (type=#{template.template_type}) in nurture step " \
                          "#{step.id}; falling back to step content"
      elsif template
        rendered = template.render(context)
        return [rendered[:subject], rendered[:body]]
      else
        Rails.logger.warn "[Nurture] Template #{step.template_id} not found, using step content"
      end
    end

    # Fallback to step content with merge fields
    company_name = entity.respond_to?(:company) ? entity.company&.name : 'us'
    subject = render_merge_fields(step.subject.presence || "Follow-up from #{company_name || 'us'}", context)
    body = render_merge_fields(step.body.presence || "This is an automated follow-up message.", context)

    [subject, body]
  end

  # ---- Attachment handling for nurture emails ----
  #
  # Returns [tracked_link_records, inline_uploads, attachment_metadata]:
  #   tracked_link_records — TrackedLink ARs created for tracked_link mode
  #   inline_uploads       — ActionDispatch::Http::UploadedFile objects to pass to CommunicationService
  #   attachment_metadata  — array of hashes to merge into Communication.metadata (already stringified)
  def process_step_attachments(step, entity, company)
    tracked_link_records = []
    inline_uploads       = []
    metadata             = []

    attachments = Array(step.attachments)
    return [tracked_link_records, inline_uploads, metadata] if attachments.empty?

    attachments.each do |att|
      filename      = att['filename']
      s3_key        = att['s3_key']
      content_type  = att['content_type']
      file_size     = att['size']
      delivery_mode = att['delivery_mode'].presence || 'tracked_link'

      next if s3_key.blank? || filename.blank?

      if delivery_mode == 'inline_attachment'
        uploaded = download_s3_object_as_upload(s3_key: s3_key, filename: filename, content_type: content_type)
        if uploaded
          inline_uploads << uploaded
          metadata << {
            filename: filename,
            delivery_mode: 'inline_attachment',
            s3_key: s3_key
          }
        else
          Rails.logger.error "[Nurture] Skipping inline attachment #{filename} (#{s3_key}) — download failed"
        end
      else
        tl = TrackedLink.create_for_attachment!(
          company:      company,
          s3_key:       s3_key,
          filename:     filename,
          content_type: content_type,
          file_size:    file_size,
          entity_type:  entity.class.name,
          entity_id:    entity.id,
          source_type:  'NurtureStep',
          source_id:    step.id
        )
        tracked_link_records << tl
        metadata << {
          filename: filename,
          delivery_mode: 'tracked_link',
          s3_key: s3_key,
          tracked_link_id: tl.id,
          tracking_url: tl.tracking_url
        }
      end
    rescue => e
      Rails.logger.error "[Nurture] Attachment processing error (#{filename}): #{e.message}"
    end

    [tracked_link_records, inline_uploads, metadata]
  end

  def append_tracked_link_section(body, tracked_links)
    return body if tracked_links.empty?

    section = tracked_links.map do |tl|
      safe_filename = ERB::Util.html_escape(tl.filename.to_s)
      "<p><a href=\"#{tl.tracking_url}\">📎 #{safe_filename}</a></p>"
    end.join("\n")

    "#{body}\n#{section}"
  end

  def download_s3_object_as_upload(s3_key:, filename:, content_type:)
    require 'aws-sdk-s3'
    s3 = Aws::S3::Client.new(
      region: ENV['AWS_REGION'] || 'us-west-2',
      access_key_id: ENV['AWS_ACCESS_KEY_ID'],
      secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
    )
    bucket = ENV['AWS_S3_BUCKET'] || 'renterinsight-website-assets-staging'

    tempfile = Tempfile.new(['nurture_att', File.extname(filename)])
    tempfile.binmode
    s3.get_object({ bucket: bucket, key: s3_key }) do |chunk|
      tempfile.write(chunk)
    end
    tempfile.rewind

    ActionDispatch::Http::UploadedFile.new(
      tempfile:     tempfile,
      filename:     filename,
      type:         content_type || 'application/octet-stream'
    )
  rescue => e
    Rails.logger.error "[Nurture] S3 download failed for #{s3_key}: #{e.message}"
    nil
  end

  # Helper to render merge fields in content
  def render_merge_fields(content, context)
    return content if content.blank?
    
    result = content.dup
    
    # Replace each merge field with its value from context
    context.each do |key, value|
      # Support both {{key}} and {{KEY}} formats
      result.gsub!(/\{\{\s*#{key}\s*\}\}/i, value.to_s)
    end
    
    result
  end
end
