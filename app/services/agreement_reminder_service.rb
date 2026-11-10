# Automatic signing reminders, run once a day by AgreementReminderJob.
#
# Reminders go out through SendAgreementReminderJob, the same job the Remind
# buttons use, which sends the way the first invite did (SendAgreementJob):
# CommunicationService email and text, the agreement's delivery method, the
# dealer company's branding, the signer's own signing link. A reminder row is
# marked sent only when a channel actually went out, and failed otherwise.
#
# This was never scheduled and only pretended to send, so agreements left out
# for signature months ago still carry a reminder frequency. The limits below
# keep those from waking up: nothing automatic goes to an agreement sent more
# than AUTO_REMINDER_WINDOW ago, and no signer gets more than
# MAX_AUTO_REMINDERS_PER_SIGNER automatic reminders. The Remind buttons are not
# limited by either.
class AgreementReminderService
  AUTO_REMINDER_WINDOW = 30.days
  MAX_AUTO_REMINDERS_PER_SIGNER = 3

  def self.check_and_send_reminders(now: Time.current)
    due_agreements(now).find_each do |agreement|
      last_reminder = agreement.last_reminder_sent_at || agreement.sent_at
      next unless last_reminder + agreement.reminder_frequency_days.days <= now

      send_reminders_for_agreement(agreement, now: now)
    end
  end

  def self.due_agreements(now = Time.current)
    Agreement.where(status: Agreement::ACTIVE_STATUSES)
             .where(is_deleted: [false, nil])
             .where('reminder_frequency_days > 0')
             .where('sent_at IS NOT NULL AND sent_at > ?', now - AUTO_REMINDER_WINDOW)
             .where('expires_at IS NULL OR expires_at > ?', now)
  end

  def self.send_reminders_for_agreement(agreement, now: Time.current)
    signers = auto_reminder_signers(agreement)
    return if signers.empty?

    signers.each { |signer| send_reminder(agreement, signer, 'auto') }

    # Spaces the next round by the frequency even when a send failed, so a dead
    # address is retried every few days rather than every day.
    agreement.update_columns(last_reminder_sent_at: now)
  end

  # Signers still expected to sign, who have not used up their automatic reminders.
  def self.auto_reminder_signers(agreement)
    agreement.pending_signers
             .where(status: [AgreementSigner::STATUS_PENDING, AgreementSigner::STATUS_VIEWED])
             .select { |signer| auto_reminders_used(agreement, signer) < MAX_AUTO_REMINDERS_PER_SIGNER }
  end

  # Failed attempts count too, so an unreachable signer is not tried forever.
  def self.auto_reminders_used(agreement, signer)
    agreement.agreement_reminders
             .where(agreement_signer_id: signer.id, reminder_type: 'auto', status: %w[sent failed])
             .count
  end

  # Sends one reminder now and returns the AgreementReminder row, marked sent or failed.
  def self.send_reminder(agreement, signer, type = 'manual')
    reminder = agreement.agreement_reminders.create!(
      agreement_signer: signer,
      scheduled_at: Time.current,
      reminder_type: type,
      channel: agreement.delivery_method == 'sms' ? 'sms' : 'email'
    )

    begin
      sent = SendAgreementReminderJob.perform_now(agreement.id, signer.id, reminder.id)
    rescue => e
      Rails.logger.error("[AgreementReminder] Reminder to signer #{signer.id} on #{agreement.agreement_number} failed: #{e.message}")
      sent = false
      reminder.mark_failed!(e.message)
    end

    reminder.reload
    reminder.mark_failed!('Not sent') if reminder.status == 'pending'

    if sent && reminder.status == 'sent'
      AgreementAuditLog.log!(agreement, AgreementAuditLog::ACTION_REMINDER_SENT,
        agreement_signer: signer,
        metadata: { type: type, channel: reminder.channel }
      )
    end

    reminder
  end
end
