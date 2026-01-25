# frozen_string_literal: true

# Job to process nurture sequence steps for enrolled leads
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

    lead = enrollment.lead
    return unless lead

    # Process the step based on type
    Rails.logger.info "[Nurture] Processing step type: #{current_step.step_type} (step_id: #{current_step.id})"
    
    case current_step.step_type
    when 'email'
      send_nurture_email(lead, current_step, enrollment)
    when 'sms'
      send_nurture_sms(lead, current_step, enrollment)
    when 'wait'
      # Wait steps are handled by scheduling
      Rails.logger.info "[Nurture] Wait step #{current_step.id} - waiting #{current_step.wait_days} days"
    when 'call'
      # Create a reminder/task for manual call
      Rails.logger.info "[Nurture] Creating call task for step #{current_step.id}"
      create_call_reminder(lead, current_step)
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

  def send_nurture_email(lead, step, enrollment)
    return unless lead.email.present?

    # Build context for merge field rendering
    context = {
      recipient_name: "#{lead.first_name} #{lead.last_name}".strip,
      first_name: lead.first_name,
      last_name: lead.last_name,
      email: lead.email,
      phone: lead.phone,
      company_name: lead.company&.name,
      location_name: lead.location&.name
    }

    # Render template if present, otherwise use step content with merge fields
    if step.template_id.present?
      template = CommunicationTemplate.find_by(id: step.template_id)
      if template
        rendered = template.render(context)
        subject = rendered[:subject]
        body = rendered[:body]
        
        Rails.logger.info "[Nurture] Using template #{template.id}: #{template.name}"
      else
        Rails.logger.warn "[Nurture] Template #{step.template_id} not found, using step content with merge fields"
        subject = render_merge_fields(step.subject.presence || "Follow-up from #{lead.company&.name || 'us'}", context)
        body = render_merge_fields(step.body.presence || "This is an automated follow-up message.", context)
      end
    else
      # Use step subject/body directly with merge field processing
      Rails.logger.info "[Nurture] Using step content with merge fields (no template)"
      subject = render_merge_fields(step.subject.presence || "Follow-up from #{lead.company&.name || 'us'}", context)
      body = render_merge_fields(step.body.presence || "This is an automated follow-up message.", context)
    end

    Rails.logger.info "[Nurture] Sending email to #{lead.email} for step #{step.id}"

    # Use CommunicationService - it handles:
    # - Waterfall settings (Location → Company → Platform)
    # - Provider selection (SMTP/SendGrid)
    # - Actual sending via configured provider
    # - Communication record creation with proper metadata
    result = CommunicationService.send_email(
      communicable: lead,
      to: lead.email,
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
    Rails.logger.warn "[Nurture] Lead #{lead.id} has opted out of email: #{e.message}"
    # Don't raise - user has opted out, continue sequence
  rescue => e
    Rails.logger.error "[Nurture] Email error for step #{step.id}: #{e.message}"
    raise # Re-raise to trigger job retry
  end

  def send_nurture_sms(lead, step, enrollment)
    return unless lead.phone.present?

    # Build context for merge field rendering
    context = {
      recipient_name: "#{lead.first_name} #{lead.last_name}".strip,
      first_name: lead.first_name,
      last_name: lead.last_name,
      email: lead.email,
      phone: lead.phone,
      company_name: lead.company&.name,
      location_name: lead.location&.name
    }

    # Render template if present, otherwise use step content with merge fields
    if step.template_id.present?
      template = CommunicationTemplate.find_by(id: step.template_id)
      if template
        rendered = template.render(context)
        body = rendered[:body] # SMS templates only have body, no subject
        
        Rails.logger.info "[Nurture] Using template #{template.id}: #{template.name}"
      else
        Rails.logger.warn "[Nurture] Template #{step.template_id} not found, using step content with merge fields"
        body = render_merge_fields(step.body.presence || "This is an automated follow-up message.", context)
      end
    else
      # Use step body directly with merge field processing
      Rails.logger.info "[Nurture] Using step content with merge fields (no template)"
      body = render_merge_fields(step.body.presence || "This is an automated follow-up message.", context)
    end

    Rails.logger.info "[Nurture] Sending SMS to #{lead.phone} for step #{step.id}"

    # Use CommunicationService - it handles:
    # - Waterfall settings (Location → Company → Platform)
    # - Twilio configuration
    # - Actual sending via Twilio API
    # - Communication record creation with proper metadata
    result = CommunicationService.send_sms(
      communicable: lead,
      to: lead.phone,
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
    Rails.logger.warn "[Nurture] Lead #{lead.id} has opted out of SMS: #{e.message}"
    # Don't raise - user has opted out, continue sequence
  rescue => e
    Rails.logger.error "[Nurture] SMS error for step #{step.id}: #{e.message}"
    raise # Re-raise to trigger job retry
  end

  def create_call_reminder(lead, step)
    # Create a call activity/task
    # Assign to lead owner or first active user
    user = lead.owner || lead.company.users.where(is_active: true).first
    return unless user

    # Calculate due date based on wait_days (if this is the first step, schedule for 1 hour from now)
    due_date = Time.current + ((step.wait_days || 0) > 0 ? step.wait_days.days : 1.hour)
    
    # Set reminder time to NOW (send notification immediately when task is created)
    reminder_time = Time.current

    activity = LeadActivity.create!(
      lead: lead,
      user: user,  # Creator
      assigned_to: user,  # ASSIGNED TO LEAD OWNER - only they will see notification
      activity_type: 'call',
      subject: "Nurture Call: #{lead.first_name} #{lead.last_name}",
      description: step.body.presence || 'Follow up call from nurture sequence',
      status: 'pending',
      priority: 'medium',
      due_date: due_date,
      phone_number: lead.phone,
      call_direction: 'outbound',
      reminder_time: reminder_time,
      reminder_method: ['popup'],  # Enable popup notifications
      reminder_sent: false,
      metadata: {
        nurture_step_id: step.id,
        nurture_sequence_id: step.nurture_sequence_id,
        source: 'nurture_sequence'
      }
    )
    
    # Note: Notification will be picked up by the polling system at /reminders/upcoming
    # The frontend polls this endpoint every 30 seconds and shows popup for activities where:
    # - reminder_time <= now
    # - reminder_sent = false
    # - status = 'pending'
    # - assigned_to = current_user (IMPORTANT: Only shows for assigned user!)
    Rails.logger.info "[Nurture] ✅ Call activity created with immediate reminder - will appear on next poll cycle"

    Rails.logger.info "[Nurture] Call activity created for lead #{lead.id}, assigned to user #{user.id}, notification sent immediately"
  rescue => e
    Rails.logger.error "[Nurture] Failed to create call activity: #{e.message}"
    # Don't raise - activity creation failure shouldn't stop the sequence
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
