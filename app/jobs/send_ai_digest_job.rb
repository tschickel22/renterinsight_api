class SendAiDigestJob < ApplicationJob
  queue_as :default

  def perform(company_id: nil)
    api_key = ENV['ANTHROPIC_API_KEY'] || Rails.application.credentials.dig(:anthropic, :api_key)
    unless api_key.present?
      Rails.logger.warn "[AiDigest] No API key — skipping digest run"
      return
    end

    service = AiDigestService.new(api_key)

    companies = if company_id
      Company.where(id: company_id)
    else
      # Companies with active subscriptions — subscription status lives in
      # tenant_subscriptions table (has_one :tenant_subscription on Company).
      Company.joins(:tenant_subscription)
             .where(tenant_subscriptions: { status: %w[active trial] })
             .order(:id)
    end

    companies.each do |company|
      limit = begin
        Setting.get('Company', company.id, 'ai_report_queries_monthly_limit', nil)&.to_i ||
        Setting.get('Platform', 0, 'ai_report_queries_monthly_limit', 0)&.to_i
      rescue
        0
      end
      next if limit <= 0

      begin
        result = service.generate_for_company(company)

        AiQueryLog.create!(
          company_id:    company.id,
          feature:       'report_ai',
          module_key:    'weekly_digest',
          execution_status: 'success',
          question:      "Weekly digest #{Date.current}",
          input_tokens:  result[:input_tokens],
          output_tokens: result[:output_tokens],
          cost_cents:    result[:cost_cents]
        )

        # Broadcast to all admin-tier users of this company (including platform
        # admins who belong to THIS company). Platform admins span all companies
        # but company.users only returns users whose company_id matches, so they
        # only get a digest for the company they actually belong to.
        admin_role_strings = [
          'Company Administrator', 'Location Administrator',
          'admin', 'company_admin', 'platform_admin', 'super_admin'
        ]

        admin_users = company.users
          .where(deleted_at: nil)
          .where(role: admin_role_strings)
          .to_a

        admin_users.each do |admin|
          # 1. Save a persistent notification so it appears in the bell
          begin
            Notification.create!(
              recipient_type: 'User',
              recipient_id:   admin.id,
              company_id:     company.id,
              notification_type: 'ai_digest',
              category:       'ai',
              priority:       'normal',
              title:          "Weekly Business Digest — #{result[:stats][:week]}",
              message:        result[:summary],
              read:           false
            )
          rescue => e
            Rails.logger.error "[AiDigest] Could not save notification for user #{admin.id}: #{e.message}"
          end

          # 2. Real-time broadcast so they see the toast immediately
          ActionCable.server.broadcast(
            "user_notifications_#{admin.id}",
            {
              type:    'ai_digest',
              title:   "📊 Weekly Business Digest",
              summary: result[:summary],
              stats:   result[:stats],
              week:    result[:stats][:week]
            }
          )

          # 3. Send digest email using existing CommunicationService stack
          begin
            if admin.email.present?
              dashboard_url = ENV['FRONTEND_URL'].presence ||
                              case Rails.env
                              when 'production' then 'https://dms.renterinsight.com'
                              when 'staging'    then 'https://staging-dms.renterinsight.com'
                              else                   'http://localhost:5173'
                              end

              html_body = <<~HTML
                <html><body>
                <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
                  <div style="background: #7c3aed; color: white; padding: 16px 24px; border-radius: 8px 8px 0 0;">
                    <h1 style="margin: 0; font-size: 20px;">📊 Weekly Business Digest</h1>
                    <p style="margin: 4px 0 0; opacity: 0.85; font-size: 13px;">#{result[:stats][:week]}</p>
                  </div>
                  <div style="background: #f9fafb; border: 1px solid #e5e7eb; border-top: none; padding: 24px; border-radius: 0 0 8px 8px;">
                    <p style="font-size: 15px; color: #111827; line-height: 1.6; margin: 0 0 24px;">#{result[:summary]}</p>
                    <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-bottom: 24px;">
                      #{[
                        ['New Leads', result[:stats][:new_leads_this_week]],
                        ['Deals Closed', result[:stats][:deals_closed_this_week]],
                        ['Pipeline', "$#{result[:stats][:pipeline_value].to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"],
                        ['Overdue Tickets', result[:stats][:overdue_service_tickets]],
                        ['Unpaid Invoices', result[:stats][:unpaid_invoices]],
                        ['Revenue This Week', "$#{result[:stats][:revenue_this_week].to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"],
                      ].map { |label, value|
                        "<div style='background: white; border: 1px solid #e5e7eb; border-radius: 6px; padding: 12px; text-align: center;'><div style='font-size: 22px; font-weight: bold; color: #7c3aed;'>#{value}</div><div style='font-size: 11px; color: #6b7280; margin-top: 2px;'>#{label}</div></div>"
                      }.join}
                    </div>
                    <div style="text-align: center;">
                      <a href="#{dashboard_url}"
                         style="background: #7c3aed; color: white; padding: 10px 24px; border-radius: 6px; text-decoration: none; font-size: 14px; font-weight: 600;">
                        Open Dashboard
                      </a>
                    </div>
                  </div>
                  <p style="text-align: center; color: #9ca3af; font-size: 11px; margin-top: 16px;">
                    Powered by Renter Insight &bull;
                    You receive this because you are an admin for #{company.name}
                  </p>
                </div>
                </body></html>
              HTML

              # Use the standard waterfall (User → Location → Company → Platform)
              # to resolve provider + from address. This matches CommunicationService.
              email_cfg = CommunicationSettingsService.for_company(company).email_config
              provider  = (email_cfg[:provider] || 'smtp').to_s.to_sym

              provider_class = case provider
              when :aws_ses                              then Providers::Email::AwsSesProvider
              when :gmail_relay                          then Providers::Email::GmailRelayProvider
              when :oauth_microsoft, :oauth_outlook      then Providers::Email::MicrosoftGraphProvider
              else                                            Providers::Email::SmtpProvider
              end

              from_email = email_cfg[:from_email].presence || Brand.from_email
              from_name  = email_cfg[:from_name].presence  || Brand.from_name

              provider_instance = provider_class.new(company: company)
              provider_instance.send_message(
                to:      admin.email,
                from:    from_email,
                subject: "📊 Weekly Business Digest — #{result[:stats][:week]} | #{company.name}",
                body:    html_body
              )

              Notification.where(
                recipient_id: admin.id,
                notification_type: 'ai_digest',
                email_sent: false
              ).order(created_at: :desc).first&.update_columns(
                email_sent: true,
                email_sent_at: Time.current
              )

              Rails.logger.info "[AiDigest] Digest email sent to #{admin.email}"
            end
          rescue => e
            Rails.logger.error "[AiDigest] Email failed for #{admin.email}: #{e.message}"
          end
        end

        Rails.logger.info "[AiDigest] Digest sent for #{company.name} (#{admin_users.count} admins notified)"

      rescue AiDigestService::DigestError => e
        Rails.logger.error "[AiDigest] Failed for company #{company.id}: #{e.message}"
      rescue => e
        Rails.logger.error "[AiDigest] Unexpected error for company #{company.id}: #{e.message}"
      end
    end
  end
end
