class SealAgreementJob < ApplicationJob
  queue_as :default

  def perform(agreement_id)
    agreement = Agreement.includes(:company, :location, :agreement_signers, :prepared_by).find_by(id: agreement_id)
    return unless agreement
    return unless agreement.status == Agreement::STATUS_COMPLETED

    # Phase 1: Seal the document (copy effective URL to sealed_document_url)
    seal_document(agreement)

    # Send completion notifications
    send_completion_notifications(agreement)

    Rails.logger.info("[SealAgreementJob] Agreement #{agreement.agreement_number} sealed and notifications sent")
  rescue => e
    Rails.logger.error("[SealAgreementJob] Failed for agreement #{agreement_id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
  end

  private

  def seal_document(agreement)
    pdf_service = AgreementPdfService.new(agreement)
    pdf_service.seal_document
  end

  def send_completion_notifications(agreement)
    branding = load_branding(agreement)
    frontend_base = frontend_url(agreement)

    # 1. Notify the document owner/preparer
    if agreement.prepared_by&.email.present?
      send_owner_completion_email(agreement, branding, frontend_base)
    end

    # 2. Send completion receipt to each signer (public link — no login required)
    agreement.agreement_signers.required_signers.signed.each do |signer|
      send_signer_completion_email(agreement, signer, branding, frontend_base)
    end

    # 3. Notify CC recipients (public link — no login required)
    agreement.agreement_signers.cc_recipients.each do |cc|
      send_cc_completion_email(agreement, cc, branding, frontend_base)
    end
  end

  # ── Owner/Preparer notification ──────────────────────────────────────

  def send_owner_completion_email(agreement, branding, frontend_base)
    owner = agreement.prepared_by
    detail_link = "#{frontend_base}/agreements/#{agreement.id}"

    subject = "✅ All signatures complete: \"#{agreement.title}\""
    body = build_email(branding) do
      signer_rows = agreement.agreement_signers.required_signers.signed.map { |s|
        "<tr><td style='padding:6px 12px;color:#1e293b;font-size:14px;'>#{ERB::Util.html_escape(s.name)}</td><td style='padding:6px 12px;color:#64748b;font-size:13px;'>#{s.signed_at&.strftime('%b %d, %Y %l:%M %p')}</td></tr>"
      }.join

      <<~INNER
        <h2 style="color: #1e293b; font-size: 20px; margin: 0 0 8px 0;">All Signatures Complete</h2>
        <p style="color: #475569; font-size: 15px; line-height: 1.5; margin: 0 0 16px 0;">
          All parties have signed <strong>"#{ERB::Util.html_escape(agreement.title)}"</strong>
          (#{ERB::Util.html_escape(agreement.agreement_number)}).
        </p>
        <table style="width:100%;border-collapse:collapse;margin-bottom:16px;">
          <thead><tr style="border-bottom:1px solid #e2e8f0;">
            <th style="padding:8px 12px;text-align:left;color:#64748b;font-size:12px;text-transform:uppercase;">Signer</th>
            <th style="padding:8px 12px;text-align:left;color:#64748b;font-size:12px;text-transform:uppercase;">Signed At</th>
          </tr></thead>
          <tbody>#{signer_rows}</tbody>
        </table>
        <table role="presentation" width="100%"><tr><td align="center" style="padding: 8px 0;">
          <a href="#{detail_link}" style="display:inline-block;padding:12px 28px;background-color:#{branding[:primary_color]};color:#ffffff;text-decoration:none;border-radius:8px;font-size:15px;font-weight:600;">
            View Agreement
          </a>
        </td></tr></table>
      INNER
    end

    CommunicationService.send_email(
      communicable: agreement,
      to: owner.email,
      subject: subject,
      body: body,
      category: 'agreements',
      skip_preference_check: true,
      metadata: { agreement_id: agreement.id, type: 'completion_owner' }
    )
    Rails.logger.info("[SealAgreementJob] ✅ Owner notification sent to #{owner.email}")
  rescue => e
    Rails.logger.error("[SealAgreementJob] ❌ Owner notification failed: #{e.message}")
  end

  # ── Signer completion receipt ────────────────────────────────────────

  def send_signer_completion_email(agreement, signer, branding, frontend_base)
    # Public link — no login required (uses signer's access token)
    public_link = "#{frontend_base}#{signer.signing_url}"

    subject = "✅ Signing complete: \"#{agreement.title}\""
    body = build_email(branding) do
      <<~INNER
        <h2 style="color: #1e293b; font-size: 20px; margin: 0 0 8px 0;">Signing Complete</h2>
        <p style="color: #475569; font-size: 15px; line-height: 1.5; margin: 0 0 8px 0;">
          Hi #{ERB::Util.html_escape(signer.name.split(' ').first)},
        </p>
        <p style="color: #475569; font-size: 15px; line-height: 1.5; margin: 0 0 16px 0;">
          All parties have signed <strong>"#{ERB::Util.html_escape(agreement.title)}"</strong>.
          A copy of the signed agreement is available for download.
        </p>
        <div style="background:#f0fdf4;border:1px solid #bbf7d0;border-radius:8px;padding:16px;text-align:center;margin-bottom:16px;">
          <p style="color:#166534;font-size:14px;font-weight:600;margin:0;">✓ All signatures collected</p>
          <p style="color:#15803d;font-size:13px;margin:4px 0 0 0;">
            Completed on #{agreement.completed_at&.strftime('%B %d, %Y at %l:%M %p')}
          </p>
        </div>
        <table role="presentation" width="100%"><tr><td align="center" style="padding: 8px 0;">
          <a href="#{public_link}" style="display:inline-block;padding:12px 28px;background-color:#{branding[:primary_color]};color:#ffffff;text-decoration:none;border-radius:8px;font-size:15px;font-weight:600;">
            View &amp; Download Agreement
          </a>
        </td></tr></table>
        <p style="color:#94a3b8;font-size:12px;margin:8px 0 0 0;text-align:center;">
          Agreement: #{ERB::Util.html_escape(agreement.agreement_number)}
        </p>
      INNER
    end

    CommunicationService.send_email(
      communicable: agreement,
      to: signer.email,
      subject: subject,
      body: body,
      category: 'agreements',
      skip_preference_check: true,
      metadata: { agreement_id: agreement.id, signer_id: signer.id, type: 'completion_signer' }
    )
    Rails.logger.info("[SealAgreementJob] ✅ Signer completion receipt sent to #{signer.email}")
  rescue => e
    Rails.logger.error("[SealAgreementJob] ❌ Signer receipt failed for #{signer.email}: #{e.message}")
  end

  # ── CC completion notification ───────────────────────────────────────

  def send_cc_completion_email(agreement, cc_signer, branding, frontend_base)
    # Public link — no login required (uses CC recipient's access token)
    public_link = "#{frontend_base}#{cc_signer.signing_url}"

    subject = "✅ All signatures complete: \"#{agreement.title}\""
    body = build_email(branding) do
      <<~INNER
        <h2 style="color: #1e293b; font-size: 20px; margin: 0 0 8px 0;">Agreement Fully Signed</h2>
        <p style="color: #475569; font-size: 15px; line-height: 1.5; margin: 0 0 8px 0;">
          Hi #{ERB::Util.html_escape(cc_signer.name.split(' ').first)},
        </p>
        <p style="color: #475569; font-size: 15px; line-height: 1.5; margin: 0 0 16px 0;">
          All parties have signed <strong>"#{ERB::Util.html_escape(agreement.title)}"</strong>
          (#{ERB::Util.html_escape(agreement.agreement_number)}).
        </p>
        <table role="presentation" width="100%"><tr><td align="center" style="padding: 8px 0;">
          <a href="#{public_link}" style="display:inline-block;padding:12px 28px;background-color:#{branding[:primary_color]};color:#ffffff;text-decoration:none;border-radius:8px;font-size:15px;font-weight:600;">
            View &amp; Download Agreement
          </a>
        </td></tr></table>
        <p style="color:#94a3b8;font-size:13px;margin:8px 0 0 0;text-align:center;">
          You received this as a CC recipient.
        </p>
      INNER
    end

    CommunicationService.send_email(
      communicable: agreement,
      to: cc_signer.email,
      subject: subject,
      body: body,
      category: 'agreements',
      skip_preference_check: true,
      metadata: { agreement_id: agreement.id, signer_id: cc_signer.id, type: 'completion_cc' }
    )
  rescue => e
    Rails.logger.error("[SealAgreementJob] ❌ CC completion notification failed for #{cc_signer.email}: #{e.message}")
  end

  # ── Shared email wrapper ─────────────────────────────────────────────

  def build_email(branding)
    logo_html = if branding[:logo_url].present?
      "<img src=\"#{branding[:logo_url]}\" alt=\"#{ERB::Util.html_escape(branding[:company_name])}\" style=\"max-height: 48px; max-width: 200px;\" />"
    else
      "<span style=\"font-size: 20px; font-weight: 700; color: #{branding[:primary_color]};\">#{ERB::Util.html_escape(branding[:company_name])}</span>"
    end

    inner_content = yield

    <<~HTML
      <!DOCTYPE html>
      <html>
      <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
      <body style="margin: 0; padding: 0; background-color: #f1f5f9; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;">
        <table role="presentation" width="100%" style="padding: 32px 16px;">
          <tr><td align="center">
            <table role="presentation" width="100%" style="max-width: 560px; background: #ffffff; border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
              <tr><td style="padding: 24px 24px 16px; text-align: center; border-bottom: 1px solid #e2e8f0;">#{logo_html}</td></tr>
              <tr><td style="padding: 24px;">#{inner_content}</td></tr>
              <tr><td style="padding: 16px 24px; background-color: #f8fafc; border-radius: 0 0 12px 12px; text-align: center;">
                <p style="color: #94a3b8; font-size: 12px; margin: 0;">Sent by #{ERB::Util.html_escape(branding[:company_name])} via secure e-signature</p>
              </td></tr>
            </table>
          </td></tr>
        </table>
      </body>
      </html>
    HTML
  end

  # ── Branding & URL helpers (reuse pattern from SendAgreementJob) ─────

  def load_branding(agreement)
    branding = { company_name: 'Platform DMS', logo_url: nil, primary_color: '#3b82f6' }

    platform_b = Setting.get('Platform', 0, 'branding', {})
    merge_branding!(branding, platform_b) if platform_b.is_a?(Hash)

    if agreement.company.present?
      company_b = Setting.get('Company', agreement.company_id, 'branding', {})
      merge_branding!(branding, company_b) if company_b.is_a?(Hash)
      branding[:company_name] = agreement.company.name if agreement.company.name.present?
    end

    if agreement.location_id.present?
      location_b = Setting.get('Location', agreement.location_id, 'branding', {})
      merge_branding!(branding, location_b) if location_b.is_a?(Hash)
    end

    if branding[:logo_url].present? && !branding[:logo_url].start_with?('http')
      api_base = ENV['RAILS_API_URL'] || 'https://localhost:3001'
      branding[:logo_url] = "#{api_base}#{branding[:logo_url]}"
    end

    branding
  end

  def merge_branding!(target, source)
    return if source.blank?
    s = source.stringify_keys
    target[:company_name]  = s['companyName']  if s['companyName'].present?
    target[:logo_url]      = s['logo']         if s['logo'].present?
    target[:primary_color] = s['primaryColor'] if s['primaryColor'].present?
  end

  def frontend_url(agreement)
    if agreement.location&.respond_to?(:custom_domain) && agreement.location.custom_domain.present?
      return "https://#{agreement.location.custom_domain}"
    end
    if agreement.company&.respond_to?(:custom_domain) && agreement.company.custom_domain.present?
      return "https://#{agreement.company.custom_domain}"
    end
    ENV['FRONTEND_URL'] || ENV['APP_URL'] || 'https://staging.crm.landlordinsight.com'
  end
end
