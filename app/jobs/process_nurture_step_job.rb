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
      create_call_reminder(lead, current_step)
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

    # Ensure we have non-blank subject and body (with defaults)
    subject = step.subject.presence || "Follow-up from #{lead.company&.name || 'us'}"
    body = step.body.presence || "This is an automated follow-up message."

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

    # Ensure we have non-blank body (with default)
    body = step.body.presence || "This is an automated follow-up message."

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
    # Create a reminder for manual call
    # Assign to lead owner or first active user
    user = lead.owner || lead.company.users.where(is_active: true).first
    return unless user

    Reminder.create!(
      lead: lead,
      user: user,
      reminder_type: 'call',
      title: "Nurture Call: #{lead.first_name} #{lead.last_name}",
      description: step.body || 'Follow up call from nurture sequence',
      due_date: Time.current + 1.hour,
      priority: 'medium',
      metadata: {
        nurture_step_id: step.id,
        nurture_sequence_id: step.nurture_sequence_id
      }
    )

    Rails.logger.info "[Nurture] Call reminder created for lead #{lead.id}, assigned to user #{user.id}"
  rescue => e
    Rails.logger.error "[Nurture] Failed to create call reminder: #{e.message}"
    # Don't raise - reminder creation failure shouldn't stop the sequence
  end
end
