# frozen_string_literal: true

# Job to process nurture sequence steps for enrolled leads
class ProcessNurtureStepJob < ApplicationJob
  queue_as :default

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
      send_email(lead, current_step)
    when 'sms'
      send_sms(lead, current_step)
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
  end

  private

  def send_email(lead, step)
    return unless lead.email.present?

    # Get settings
    settings = get_communication_settings
    email_config = settings.dig(:communications, :email) || {}

    unless email_configured?(email_config)
      Rails.logger.warn "[Nurture] Email not configured, skipping step #{step.id}"
      return
    end

    # Create communication log
    log = CommunicationLog.create!(
      lead: lead,
      comm_type: 'email',
      direction: 'outbound',
      subject: step.subject || 'Nurture Email',
      content: step.body || '',
      status: 'sent',
      sent_at: Time.current,
      metadata: {
        provider: email_config[:provider] || 'smtp',
        from_email: email_config[:fromEmail],
        from_name: email_config[:fromName],
        nurture_step_id: step.id,
        nurture_sequence_id: step.nurture_sequence_id
      }
    )

    # TODO: Actually send email via configured provider (SMTP, SendGrid, etc.)
    # For now, just log it
    Rails.logger.info "[Nurture] Email sent to #{lead.email}: #{step.subject} (log_id: #{log.id})"
  end

  def send_sms(lead, step)
    return unless lead.phone.present?

    # Get settings
    settings = get_communication_settings
    sms_config = settings.dig(:communications, :sms) || {}

    unless sms_configured?(sms_config)
      Rails.logger.warn "[Nurture] SMS not configured, skipping step #{step.id}"
      return
    end

    # Create communication log
    log = CommunicationLog.create!(
      lead: lead,
      comm_type: 'sms',
      direction: 'outbound',
      content: step.body || '',
      status: 'sent',
      sent_at: Time.current,
      metadata: {
        provider: sms_config[:provider] || 'twilio',
        from_number: sms_config[:fromNumber],
        nurture_step_id: step.id,
        nurture_sequence_id: step.nurture_sequence_id
      }
    )

    # TODO: Actually send SMS via configured provider (Twilio, etc.)
    # For now, just log it
    Rails.logger.info "[Nurture] SMS sent to #{lead.phone}: #{step.body[0..50]}... (log_id: #{log.id})"
  end

  def create_call_reminder(lead, step)
    # Create a reminder for manual call
    user = User.first # TODO: Assign to proper user
    return unless user

    Reminder.create!(
      lead: lead,
      user: user,
      reminder_type: 'call',
      title: "Nurture Call: #{lead.first_name} #{lead.last_name}",
      description: step.body || 'Follow up call from nurture sequence',
      due_date: Time.current + 1.hour,
      priority: 'medium'
    )

    Rails.logger.info "[Nurture] Call reminder created for lead #{lead.id}"
  end

  def get_communication_settings
    # Fetch platform settings
    platform_settings = fetch_platform_settings
    company_settings = fetch_company_settings

    # Merge (company overrides platform)
    merge_settings(platform_settings, company_settings)
  end

  def fetch_platform_settings
    {
      communications: {
        email: {
          provider: 'smtp',
          fromEmail: 'platform@renterinsight.com',
          fromName: 'RenterInsight Platform',
          isEnabled: true
        },
        sms: {
          provider: 'twilio',
          fromNumber: '+1234567890',
          isEnabled: false
        }
      }
    }
  end

  def fetch_company_settings
    # TODO: Fetch from company settings when implemented
    {}
  end

  def merge_settings(platform, company)
    result = platform.deep_dup

    if company.dig(:communications, :email)
      result[:communications] ||= {}
      result[:communications][:email] ||= {}
      result[:communications][:email].merge!(company[:communications][:email])
    end

    if company.dig(:communications, :sms)
      result[:communications] ||= {}
      result[:communications][:sms] ||= {}
      result[:communications][:sms].merge!(company[:communications][:sms])
    end

    result
  end

  def email_configured?(config)
    config[:isEnabled] == true &&
    config[:fromEmail].present? &&
    (config[:provider].present? || config[:smtpHost].present?)
  end

  def sms_configured?(config)
    config[:isEnabled] == true &&
    config[:fromNumber].present? &&
    config[:provider].present?
  end
end
