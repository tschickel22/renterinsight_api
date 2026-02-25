class SendAgreementJob < ApplicationJob
  queue_as :default

  def perform(agreement_id)
    agreement = Agreement.includes(:company, :location, :agreement_signers, :prepared_by).find_by(id: agreement_id)
    return unless agreement
    return unless agreement.status == Agreement::STATUS_SENT

    branding = load_branding(agreement)
    frontend_base = frontend_url(agreement)

    agreement.agreement_signers.each do |signer|
      next if signer.is_cc?

      signing_link = "#{frontend_base}#{signer.signing_url}"

      begin
        # Email (always sent unless delivery_method is 'sms' only)
        if agreement.delivery_method != 'sms'
          send_signing_email(agreement, signer, signing_link, branding)
        end

        # SMS (sent when delivery_method is 'sms' or 'both')
        if %w[sms both].include?(agreement.delivery_method) && signer.phone.present?
          send_signing_sms(agreement, signer, signing_link, branding)
        end
      rescue => e
        Rails.logger.error("[SendAgreementJob] Failed to send to #{signer.email}: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
      end
    end

    # Notify CC recipients (email-only, no signing link needed)
    agreement.agreement_signers.cc_recipients.each do |cc|
      begin
        send_cc_notification(agreement, cc, branding)
      rescue => e
        Rails.logger.error("[SendAgreementJob] Failed to notify CC #{cc.email}: #{e.message}")
      end
    end
  end

  private

  # ── Email to signer ──────────────────────────────────────────────────

  def send_signing_email(agreement, signer, signing_link, branding)
    subject = "#{branding[:company_name]}: Please sign \"#{agreement.title}\""
    body    = build_signing_email_html(agreement, signer, signing_link, branding)

    result = CommunicationService.send_email(
      communicable: agreement,
      to: signer.email,
      subject: subject,
      body: body,
      category: 'agreements',
      skip_preference_check: true, # Signing invitations always go through
      metadata: {
        agreement_id: agreement.id,
        signer_id: signer.id,
        type: 'signing_invitation'
      }
    )

    if result[:success]
      Rails.logger.info("[SendAgreementJob] ✅ Email sent to #{signer.email} for agreement #{agreement.agreement_number}")
    else
      Rails.logger.error("[SendAgreementJob] ❌ Email failed for #{signer.email}: #{result[:error]}")
    end
  end

  # ── SMS to signer ────────────────────────────────────────────────────

  def send_signing_sms(agreement, signer, signing_link, branding)
    body = "#{branding[:company_name]}: You have a document to sign — \"#{agreement.title}\". Sign here: #{signing_link}"

    result = CommunicationService.send_sms(
      communicable: agreement,
      to: signer.phone,
      body: body,
      category: 'agreements',
      skip_preference_check: true,
      metadata: {
        agreement_id: agreement.id,
        signer_id: signer.id,
        type: 'signing_invitation_sms'
      }
    )

    if result[:success]
      Rails.logger.info("[SendAgreementJob] ✅ SMS sent to #{signer.phone} for agreement #{agreement.agreement_number}")
    else
      Rails.logger.error("[SendAgreementJob] ❌ SMS failed for #{signer.phone}: #{result[:error]}")
    end
  end

  # ── CC notification ──────────────────────────────────────────────────

  def send_cc_notification(agreement, cc_signer, branding)
    subject = "#{branding[:company_name]}: \"#{agreement.title}\" sent for signing"
    body    = build_cc_email_html(agreement, cc_signer, branding)

    CommunicationService.send_email(
      communicable: agreement,
      to: cc_signer.email,
      subject: subject,
      body: body,
      category: 'agreements',
      skip_preference_check: true,
      metadata: {
        agreement_id: agreement.id,
        signer_id: cc_signer.id,
        type: 'cc_notification'
      }
    )
  end

  # ── Branding waterfall: Location → Company → Platform ────────────────

  def load_branding(agreement)
    # Platform defaults
    branding = {
      company_name: 'Platform DMS',
      logo_url: nil,
      primary_color: '#3b82f6',
      secondary_color: '#64748b'
    }

    # Platform branding
    platform_raw = Setting.get('Platform', 0, 'branding', {})
    platform_b   = platform_raw.is_a?(Hash) ? platform_raw : {}
    merge_branding!(branding, platform_b)

    # Company branding (overrides platform)
    if agreement.company.present?
      company_raw = Setting.get('Company', agreement.company_id, 'branding', {})
      company_b   = company_raw.is_a?(Hash) ? company_raw : {}
      merge_branding!(branding, company_b)

      # Company name fallback
      branding[:company_name] = agreement.company.name if agreement.company.name.present?
    end

    # Location branding (highest priority — overrides company)
    if agreement.location_id.present?
      location_raw = Setting.get('Location', agreement.location_id, 'branding', {})
      location_b   = location_raw.is_a?(Hash) ? location_raw : {}
      merge_branding!(branding, location_b)

      # Location name overrides company name if set in branding
      branding[:company_name] = location_b['companyName'] || location_b[:companyName] if (location_b['companyName'] || location_b[:companyName]).present?
    end

    # Ensure logo is absolute
    if branding[:logo_url].present? && !branding[:logo_url].start_with?('http')
      api_base = ENV['RAILS_API_URL'] || 'https://localhost:3001'
      branding[:logo_url] = "#{api_base}#{branding[:logo_url]}"
    end

    branding
  end

  def merge_branding!(target, source)
    return if source.blank?
    s = source.stringify_keys

    target[:company_name]   = s['companyName']   if s['companyName'].present?
    target[:logo_url]       = s['logo']          if s['logo'].present?
    target[:primary_color]  = s['primaryColor']  if s['primaryColor'].present?
    target[:secondary_color]= s['secondaryColor']if s['secondaryColor'].present?
  end

  # ── Frontend URL resolution ──────────────────────────────────────────

  def frontend_url(agreement)
    # Check for location or company custom domain first
    if agreement.location&.respond_to?(:custom_domain) && agreement.location.custom_domain.present?
      return "https://#{agreement.location.custom_domain}"
    end

    if agreement.company&.respond_to?(:custom_domain) && agreement.company.custom_domain.present?
      return "https://#{agreement.company.custom_domain}"
    end

    # Fall back to environment variable
    ENV['FRONTEND_URL'] || ENV['APP_URL'] || 'https://staging.crm.landlordinsight.com'
  end

  # ── Email templates ──────────────────────────────────────────────────

  def build_signing_email_html(agreement, signer, signing_link, branding)
    preparer_name = agreement.prepared_by&.name || branding[:company_name]
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

    expires_line = agreement.expires_at.present? ? "<p style=\"color: #94a3b8; font-size: 12px; margin: 16px 0 0 0;\">This signing request expires on #{agreement.expires_at.strftime('%B %d, %Y')}.</p>" : ''

    logo_html = branding[:logo_url].present? ? "<img src=\"#{branding[:logo_url]}\" alt=\"#{ERB::Util.html_escape(branding[:company_name])}\" style=\"max-height: 48px; max-width: 200px;\" />" : "<span style=\"font-size: 20px; font-weight: 700; color: #{branding[:primary_color]};\">#{ERB::Util.html_escape(branding[:company_name])}</span>"

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
                    <h2 style="color: #1e293b; font-size: 20px; margin: 0 0 8px 0;">Document Ready for Signing</h2>
                    <p style="color: #475569; font-size: 15px; line-height: 1.5; margin: 0 0 4px 0;">
                      Hi #{ERB::Util.html_escape(signer.name.split(' ').first)},
                    </p>
                    <p style="color: #475569; font-size: 15px; line-height: 1.5; margin: 0 0 20px 0;">
                      #{ERB::Util.html_escape(preparer_name)} has sent you
                      <strong>"#{ERB::Util.html_escape(agreement.title)}"</strong> to review and sign.
                    </p>
                    #{custom_message}
                    <!-- CTA Button -->
                    <table role="presentation" width="100%">
                      <tr>
                        <td align="center" style="padding: 8px 0;">
                          <a href="#{signing_link}" style="display: inline-block; padding: 14px 32px; background-color: #{branding[:primary_color]}; color: #ffffff; text-decoration: none; border-radius: 8px; font-size: 16px; font-weight: 600;">
                            Review & Sign
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

  def build_cc_email_html(agreement, cc_signer, branding)
    preparer_name = agreement.prepared_by&.name || branding[:company_name]
    signer_names  = agreement.agreement_signers
                      .where(role: [AgreementSigner::ROLE_SIGNER, AgreementSigner::ROLE_COUNTER_SIGNER])
                      .pluck(:name).join(', ')

    logo_html = branding[:logo_url].present? ? "<img src=\"#{branding[:logo_url]}\" alt=\"#{ERB::Util.html_escape(branding[:company_name])}\" style=\"max-height: 48px; max-width: 200px;\" />" : "<span style=\"font-size: 20px; font-weight: 700; color: #{branding[:primary_color]};\">#{ERB::Util.html_escape(branding[:company_name])}</span>"

    <<~HTML
      <!DOCTYPE html>
      <html>
      <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
      <body style="margin: 0; padding: 0; background-color: #f1f5f9; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;">
        <table role="presentation" width="100%" style="padding: 32px 16px;">
          <tr>
            <td align="center">
              <table role="presentation" width="100%" style="max-width: 560px; background: #ffffff; border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
                <tr>
                  <td style="padding: 24px 24px 16px; text-align: center; border-bottom: 1px solid #e2e8f0;">
                    #{logo_html}
                  </td>
                </tr>
                <tr>
                  <td style="padding: 24px;">
                    <h2 style="color: #1e293b; font-size: 20px; margin: 0 0 8px 0;">Agreement Sent for Signing</h2>
                    <p style="color: #475569; font-size: 15px; line-height: 1.5; margin: 0 0 4px 0;">
                      Hi #{ERB::Util.html_escape(cc_signer.name.split(' ').first)},
                    </p>
                    <p style="color: #475569; font-size: 15px; line-height: 1.5; margin: 0 0 16px 0;">
                      #{ERB::Util.html_escape(preparer_name)} has sent
                      <strong>"#{ERB::Util.html_escape(agreement.title)}"</strong> to the following for signing:
                    </p>
                    <p style="color: #1e293b; font-size: 14px; font-weight: 500; margin: 0;">#{ERB::Util.html_escape(signer_names)}</p>
                    <p style="color: #94a3b8; font-size: 13px; margin: 12px 0 0 0;">
                      You are receiving this as a CC recipient. You'll be notified when signing is complete.
                    </p>
                  </td>
                </tr>
                <tr>
                  <td style="padding: 16px 24px; background-color: #f8fafc; border-radius: 0 0 12px 12px; text-align: center;">
                    <p style="color: #94a3b8; font-size: 12px; margin: 0;">
                      Sent by #{ERB::Util.html_escape(branding[:company_name])} via secure e-signature
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
