class SendAgreementReminderJob < ApplicationJob
  queue_as :default

  def perform(agreement_id, signer_id)
    agreement = Agreement.includes(:company, :location, :agreement_signers, :prepared_by).find_by(id: agreement_id)
    return unless agreement

    signer = agreement.agreement_signers.find_by(id: signer_id)
    return unless signer
    return if signer.status == AgreementSigner::STATUS_SIGNED || signer.status == AgreementSigner::STATUS_DECLINED

    # Reuse SendAgreementJob's branding/email infrastructure
    sender = SendAgreementJob.new
    branding = sender.send(:load_branding, agreement)
    frontend_base = sender.send(:frontend_url, agreement)
    signing_link = "#{frontend_base}#{signer.signing_url}"

    begin
      results = []  # Track [success, error] for each attempted channel

      # Email reminder
      if agreement.delivery_method != 'sms'
        results << send_reminder_email(agreement, signer, signing_link, branding)
      end

      # SMS reminder
      if %w[sms both].include?(agreement.delivery_method) && signer.phone.present?
        results << send_reminder_sms(agreement, signer, signing_link, branding)
      end

      # Push rides alongside rather than counting as a delivery channel: the
      # reminder record tracks email/SMS, and a signer with no portal app must
      # not make an email-only reminder look like it failed.
      PortalPushService.document_signature_reminder(agreement: agreement, signer: signer)

      any_success = results.any? { |success, _| success }
      last_error = results.select { |success, _| !success }.map { |_, err| err }.last

      # Mark the reminder record based on actual delivery result
      reminder = agreement.agreement_reminders
                   .where(agreement_signer_id: signer.id, status: 'pending')
                   .order(created_at: :desc).first

      if any_success
        reminder&.update(sent_at: Time.current, status: 'sent')
      else
        reminder&.update(status: 'failed', error_message: last_error || 'All delivery channels failed')
      end

    rescue => e
      Rails.logger.error("[SendAgreementReminderJob] Failed for signer #{signer.email}: #{e.message}\n#{e.backtrace.first(3).join("\n")}")

      reminder = agreement.agreement_reminders
                   .where(agreement_signer_id: signer.id, status: 'pending')
                   .order(created_at: :desc).first
      reminder&.update(status: 'failed', error_message: e.message)
    end
  end

  private

  def send_reminder_email(agreement, signer, signing_link, branding)
    subject = "Reminder: Please sign \"#{agreement.title}\""
    body    = build_reminder_email_html(agreement, signer, signing_link, branding)

    result = CommunicationService.send_email(
      communicable: agreement,
      to: signer.email,
      subject: subject,
      body: body,
      category: 'agreements',
      skip_preference_check: true,
      metadata: {
        agreement_id: agreement.id,
        signer_id: signer.id,
        type: 'signing_reminder'
      }
    )

    if result[:success]
      Rails.logger.info("[SendAgreementReminderJob] ✅ Reminder email sent to #{signer.email} for #{agreement.agreement_number}")
      return [true, nil]
    else
      Rails.logger.error("[SendAgreementReminderJob] ❌ Reminder email failed for #{signer.email}: #{result[:error]}")
      return [false, result[:error]]
    end
  end

  def send_reminder_sms(agreement, signer, signing_link, branding)
    body = "Reminder from #{branding[:company_name]}: \"#{agreement.title}\" is waiting for your signature. Sign here: #{signing_link}"

    result = CommunicationService.send_sms(
      communicable: agreement,
      to: signer.phone,
      body: body,
      category: 'agreements',
      skip_preference_check: true,
      metadata: {
        agreement_id: agreement.id,
        signer_id: signer.id,
        type: 'signing_reminder_sms'
      }
    )

    if result[:success]
      Rails.logger.info("[SendAgreementReminderJob] ✅ Reminder SMS sent to #{signer.phone}")
      return [true, nil]
    else
      Rails.logger.error("[SendAgreementReminderJob] ❌ Reminder SMS failed for #{signer.phone}: #{result[:error]}")
      return [false, result[:error]]
    end
  end

  def build_reminder_email_html(agreement, signer, signing_link, branding)
    preparer_name = agreement.prepared_by&.name || branding[:company_name]
    expires_line = agreement.expires_at.present? ? "<p style=\"color: #dc2626; font-size: 13px; margin: 16px 0 0 0;\">⏰ This request expires on #{agreement.expires_at.strftime('%B %d, %Y')}.</p>" : ''

    custom_message = agreement.message_to_signers.present? ? <<~MSG : ''
      <tr>
        <td style="padding: 16px 24px; background-color: #f8fafc; border-radius: 8px; margin-bottom: 16px;">
          <p style="color: #475569; font-size: 14px; margin: 0; font-style: italic;">
            "#{ERB::Util.html_escape(agreement.message_to_signers)}"
          </p>
          <p style="color: #94a3b8; font-size: 12px; margin: 8px 0 0 0;">— #{ERB::Util.html_escape(preparer_name)}</p>
        </td>
      </tr>
      <tr><td style="height: 16px;"></td></tr>
    MSG

    logo_html = branding[:logo_url].present? ?
      "<img src=\"#{branding[:logo_url]}\" alt=\"#{ERB::Util.html_escape(branding[:company_name])}\" style=\"max-height: 48px; max-width: 200px;\" />" :
      "<span style=\"font-size: 20px; font-weight: 700; color: #{branding[:primary_color]};\">#{ERB::Util.html_escape(branding[:company_name])}</span>"

    <<~HTML
      <!DOCTYPE html>
      <html>
      <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
      <body style="margin: 0; padding: 0; background-color: #f1f5f9; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;">
        <table role="presentation" width="100%" style="padding: 32px 16px;">
          <tr>
            <td align="center">
              <table role="presentation" width="100%" style="max-width: 560px; background: #ffffff; border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
                <!-- Header -->
                <tr>
                  <td style="padding: 24px 24px 16px; text-align: center; border-bottom: 1px solid #e2e8f0;">
                    #{logo_html}
                  </td>
                </tr>
                <!-- Body -->
                <tr>
                  <td style="padding: 24px;">
                    <p style="display: inline-block; padding: 4px 12px; background-color: #fef3c7; color: #92400e; border-radius: 9999px; font-size: 12px; font-weight: 600; margin: 0 0 16px 0;">
                      ⏳ Reminder
                    </p>
                    <h2 style="color: #1e293b; font-size: 20px; margin: 0 0 8px 0;">Your signature is still needed</h2>
                    <p style="color: #475569; font-size: 15px; line-height: 1.5; margin: 0 0 4px 0;">
                      Hi #{ERB::Util.html_escape(signer.name.split(' ').first)},
                    </p>
                    <p style="color: #475569; font-size: 15px; line-height: 1.5; margin: 0 0 20px 0;">
                      #{ERB::Util.html_escape(preparer_name)} is waiting for you to sign
                      <strong>"#{ERB::Util.html_escape(agreement.title)}"</strong>.
                    </p>
                    #{custom_message}
                    <!-- CTA Button -->
                    <table role="presentation" width="100%">
                      <tr>
                        <td align="center" style="padding: 8px 0;">
                          <a href="#{signing_link}" style="display: inline-block; padding: 14px 32px; background-color: #{branding[:primary_color]}; color: #ffffff; text-decoration: none; border-radius: 8px; font-size: 16px; font-weight: 600;">
                            Review & Sign Now
                          </a>
                        </td>
                      </tr>
                    </table>
                    #{expires_line}
                  </td>
                </tr>
                <!-- Footer -->
                <tr>
                  <td style="padding: 16px 24px; background-color: #f8fafc; border-radius: 0 0 12px 12px; text-align: center;">
                    <p style="color: #94a3b8; font-size: 12px; margin: 0;">
                      Sent by #{ERB::Util.html_escape(branding[:company_name])} via secure e-signature
                    </p>
                    <p style="color: #cbd5e1; font-size: 11px; margin: 8px 0 0 0;">
                      If you didn't expect this, you can safely ignore this email.
                    </p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
      </html>
    HTML
  end
end
