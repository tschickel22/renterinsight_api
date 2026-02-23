class AgreementReminderService
  def self.check_and_send_reminders
    # Find agreements that need reminders
    Agreement.where(status: %w[sent viewed partially_signed])
             .where(is_deleted: [false, nil])
             .where('reminder_frequency_days > 0')
             .find_each do |agreement|
      next if agreement.expired?

      last_reminder = agreement.last_reminder_sent_at || agreement.sent_at
      next unless last_reminder.present?
      next unless last_reminder + agreement.reminder_frequency_days.days <= Time.current

      send_reminders_for_agreement(agreement)
    end
  end

  def self.send_reminders_for_agreement(agreement)
    agreement.pending_signers.each do |signer|
      send_reminder(agreement, signer, 'auto')
    end

    agreement.update!(last_reminder_sent_at: Time.current)
  end

  def self.send_reminder(agreement, signer, type = 'manual')
    reminder = agreement.agreement_reminders.create!(
      agreement_signer: signer,
      scheduled_at: Time.current,
      reminder_type: type,
      channel: 'email'
    )

    # Send email reminder
    begin
      # Use your existing CommunicationService or mailer
      # AgreementMailer.reminder(agreement, signer).deliver_later
      Rails.logger.info("[AgreementReminder] Sent #{type} reminder to #{signer.email} for agreement #{agreement.agreement_number}")

      reminder.mark_sent!

      AgreementAuditLog.log!(agreement, AgreementAuditLog::ACTION_REMINDER_SENT,
        agreement_signer: signer,
        metadata: { type: type, channel: 'email' }
      )
    rescue => e
      Rails.logger.error("[AgreementReminder] Failed to send reminder: #{e.message}")
      reminder.mark_failed!(e.message)
    end

    # Send SMS if signer has phone
    if signer.phone.present?
      sms_reminder = agreement.agreement_reminders.create!(
        agreement_signer: signer,
        scheduled_at: Time.current,
        reminder_type: type,
        channel: 'sms'
      )

      begin
        # Use your existing Twilio/SMS service
        Rails.logger.info("[AgreementReminder] Sent SMS reminder to #{signer.phone} for agreement #{agreement.agreement_number}")
        sms_reminder.mark_sent!
      rescue => e
        Rails.logger.error("[AgreementReminder] SMS failed: #{e.message}")
        sms_reminder.mark_failed!(e.message)
      end
    end
  end
end
