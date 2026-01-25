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
    when 'call'
      # Create a reminder/task for manual call
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

    Rails.logger.info "[Nurture] Sending email to #{email} for #{entity.class.name} #{entity.id}, step #{step.id}"

    # Use CommunicationService - it handles:
    # - Waterfall settings (Location → Company → Platform)
    # - Provider selection (SMTP/SendGrid)
    # - Actual sending via configured provider
    # - Communication record creation with proper metadata
    result = CommunicationService.send_email(
      communicable: entity,
      to: email,
      subject: subject,
      body: body,
      category: 'nurture',
      metadata: {
        nurture_step_id: step.id,
        nurture_sequence_id: step.nurture_sequence_id,
        nurture_enrollment_id: enrollment.id,
        step_type: 'email',
        step_position: step.position
      },
      skip_preference_check: false # Respect user email preferences
    )

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
    user = lead.owner || lead.company.users.where(is_active: true).first
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
    user = contact.owner || contact.company.users.where(is_active: true).first
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
  def render_content(step, context, entity)
    if step.template_id.present?
      template = CommunicationTemplate.find_by(id: step.template_id)
      if template
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
