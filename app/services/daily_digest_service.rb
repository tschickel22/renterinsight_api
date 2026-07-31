# frozen_string_literal: true

require 'mail'
require 'net/http'
require 'uri'
require 'json'

# Sends a single user a daily summary of their workqueue counts.
#
#   DailyDigestService.new(user).send_digest!
#
# Email is delivered via the user's default verified email connection using
# OAuth SMTP + XOAUTH2 (works for both oauth_gmail and oauth_outlook). Plain
# SMTP connections are not yet supported here — callers should gate on
# user.has_email_connection? and surface a friendly error otherwise.
class DailyDigestService
  FRONTEND_URL = ENV.fetch('FRONTEND_URL', 'https://staging-dms.renterinsight.com')

  def initialize(user)
    @user = user
  end

  def send_digest!
    company = @user.company
    return { success: false, error: 'User has no company' } unless company

    connection = @user.default_email_connection
    return { success: false, error: 'No verified email connection found' } unless connection
    return { success: false, error: 'Only OAuth email connections are supported for digests' } unless connection.oauth_provider?

    summary = WorkqueueService.new(company: company, user: @user).summary
    total = total_item_count(summary)

    company_name = company.name.presence || Brand.current.name
    subject = "[#{company_name}] Your Daily Workqueue Summary, #{Date.current.strftime('%B %-d, %Y')}"
    html_body = build_html(summary, total)

    send_result = case connection.provider.to_s
                  when 'oauth_outlook', 'oauth_microsoft'
                    deliver_via_microsoft_graph(connection, subject, html_body)
                  else
                    deliver_via_oauth_smtp(connection, subject, html_body)
                  end
    return send_result unless send_result[:success]

    record_last_sent!
    { success: true, message_id: send_result[:message_id] }
  rescue => e
    Rails.logger.error("[DailyDigestService] Error: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
    { success: false, error: e.message }
  end

  private

  def total_item_count(summary)
    summary.sum { |group| group[:queues].sum { |q| q[:count].to_i } }
  end

  def first_name
    @user.try(:first_name).presence || @user.email.to_s.split('@').first
  end

  def build_html(summary, total)
    queue_url   = ->(qid) { "#{FRONTEND_URL}/workqueue?queue=#{qid}" }
    workqueue_url = "#{FRONTEND_URL}/workqueue"

    groups_html = summary.map do |group|
      visible = group[:queues].select { |q| q[:count].to_i.positive? }
      next if visible.empty?

      queue_rows = visible.map do |q|
        <<~HTML
          <tr>
            <td style="padding:8px 0;border-bottom:1px solid #eee;">
              <a href="#{queue_url.call(q[:id])}" style="color:#2563eb;text-decoration:none;font-size:15px;">#{q[:label]}</a>
            </td>
            <td style="padding:8px 0;border-bottom:1px solid #eee;text-align:right;font-weight:600;color:#111;">#{q[:count]}</td>
          </tr>
        HTML
      end.join

      <<~HTML
        <div style="margin:24px 0;">
          <h2 style="margin:0 0 8px 0;font-size:16px;color:#374151;text-transform:uppercase;letter-spacing:.05em;">#{group[:label]}</h2>
          <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="border-collapse:collapse;">
            #{queue_rows}
          </table>
        </div>
      HTML
    end.compact.join

    if groups_html.empty?
      groups_html = <<~HTML
        <p style="color:#6b7280;font-size:15px;margin:24px 0;">
          You're all clear — no open items across your queues today. Nice work.
        </p>
      HTML
    end

    <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Your Daily Workqueue Summary</title>
      </head>
      <body style="margin:0;padding:0;background:#f5f6f8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#111;">
        <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background:#f5f6f8;padding:24px 0;">
          <tr>
            <td align="center">
              <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="600" style="max-width:600px;width:100%;background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,0.06);">
                <tr>
                  <td style="padding:32px 32px 16px 32px;">
                    <h1 style="margin:0 0 8px 0;font-size:22px;color:#111;">Good morning, #{first_name}!</h1>
                    <p style="margin:0;color:#4b5563;font-size:15px;">
                      You have <strong style="color:#111;">#{total}</strong> open #{total == 1 ? 'item' : 'items'} across your queues.
                    </p>
                  </td>
                </tr>
                <tr>
                  <td style="padding:0 32px 16px 32px;">
                    #{groups_html}
                  </td>
                </tr>
                <tr>
                  <td align="center" style="padding:8px 32px 32px 32px;">
                    <a href="#{workqueue_url}"
                       style="display:inline-block;background:#2563eb;color:#fff;text-decoration:none;font-weight:600;font-size:15px;padding:12px 24px;border-radius:6px;">
                      Open Workqueue
                    </a>
                  </td>
                </tr>
                <tr>
                  <td style="padding:16px 32px 32px 32px;border-top:1px solid #eee;">
                    <p style="margin:0;color:#9ca3af;font-size:12px;line-height:1.5;">
                      You're receiving this because daily digests are enabled on your account.
                      Disable daily digests in Account Settings.
                    </p>
                    <p style="margin:12px 0 0 0;color:#9ca3af;font-size:12px;line-height:1.5;">
                      Powered by <a href="#{Brand.current.website_url}" style="color:#9ca3af;text-decoration:none;">#{Brand.current.name}</a>
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

  def deliver_via_microsoft_graph(connection, subject, html_body)
    access_token = connection.oauth_token_encrypted
    if connection.respond_to?(:oauth_token_expired?) && connection.oauth_token_expired?
      refreshed = connection.refresh_oauth_token!(scope: 'https://graph.microsoft.com/Mail.Send offline_access')
      access_token = refreshed if refreshed
    end
    return { success: false, error: 'No valid OAuth access token for Microsoft Graph' } unless access_token.present?

    message = {
      subject: subject,
      body: { contentType: 'HTML', content: html_body },
      toRecipients: [{ emailAddress: { address: @user.email } }]
    }
    payload = { message: message, saveToSentItems: true }

    uri = URI('https://graph.microsoft.com/v1.0/me/sendMail')
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{access_token}"
    request['Content-Type'] = 'application/json'
    request.body = payload.to_json

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
      http.request(request)
    end

    if response.code.to_i == 202
      connection.record_usage! if connection.respond_to?(:record_usage!)
      { success: true, message_id: response['x-ms-request-id'] || "graph-#{SecureRandom.hex(8)}" }
    else
      error_msg = begin
        JSON.parse(response.body).dig('error', 'message')
      rescue
        response.body.to_s[0, 200]
      end
      Rails.logger.error("[DailyDigestService#deliver_via_microsoft_graph] Failed (#{response.code}): #{error_msg}")
      connection.record_error!(error_msg) if connection.respond_to?(:record_error!)
      { success: false, error: "Microsoft Graph API error (#{response.code}): #{error_msg}" }
    end
  rescue => e
    Rails.logger.error("[DailyDigestService#deliver_via_microsoft_graph] #{e.message}")
    connection.record_error!(e.message) if connection.respond_to?(:record_error!)
    { success: false, error: e.message }
  end

  def deliver_via_oauth_smtp(connection, subject, html_body)
    access_token = ensure_access_token(connection)
    return { success: false, error: 'No valid OAuth access token' } unless access_token.present?

    oauth_email = connection.email_address
    from_name   = connection.display_name.presence || @user.try(:full_name).presence || oauth_email
    to_address  = @user.email

    smtp_host, smtp_port = case connection.provider
                           when 'oauth_outlook' then ['smtp.office365.com', 587]
                           when 'oauth_gmail'   then ['smtp.gmail.com', 587]
                           else ['smtp.gmail.com', 587]
                           end

    mail = Mail.new do
      from    "#{from_name} <#{oauth_email}>"
      to      to_address
      subject subject

      html_part do
        content_type 'text/html; charset=UTF-8'
        body html_body
      end
    end

    mail.delivery_method :smtp, {
      address:              smtp_host,
      port:                 smtp_port,
      user_name:            oauth_email,
      password:             access_token,
      authentication:       :xoauth2,
      enable_starttls_auto: true
    }

    mail.deliver!
    connection.record_usage!

    { success: true, message_id: mail.message_id }
  rescue => e
    Rails.logger.error("[DailyDigestService#deliver_via_oauth_smtp] #{e.message}")
    connection.record_error!(e.message) if connection.respond_to?(:record_error!)
    { success: false, error: e.message }
  end

  # Returns a usable OAuth access token, refreshing if it's within 5 minutes of expiry.
  def ensure_access_token(connection)
    token = connection.oauth_token_encrypted
    needs_refresh = connection.oauth_expires_at.nil? ||
                    connection.oauth_expires_at <= 5.minutes.from_now

    if needs_refresh && connection.oauth_refresh_token_encrypted.present?
      refreshed = connection.refresh_oauth_token!
      token = refreshed if refreshed
    end
    token
  end

  def record_last_sent!
    return unless @user.respond_to?(:daily_digest_last_sent_at)
    @user.update_column(:daily_digest_last_sent_at, Time.current)
  rescue => e
    Rails.logger.warn("[DailyDigestService] Failed to record last_sent_at: #{e.message}")
  end
end
