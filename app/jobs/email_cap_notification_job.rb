# frozen_string_literal: true

class EmailCapNotificationJob < ApplicationJob
  queue_as :default

  def perform(company_id, threshold)
    company = Company.find_by(id: company_id)
    return unless company

    limit   = company.email_monthly_limit
    current = EmailCapService.current_period_count(company)
    period  = EmailCapService.current_billing_period

    message = case threshold.to_sym
              when :approaching_cap
                "Email usage alert for #{company.name}: #{current}/#{limit} campaign emails used this month (#{period}). Approaching your limit."
              when :at_cap
                "Email cap reached for #{company.name}: #{current}/#{limit} campaign emails used this month (#{period}). Automated campaign sends are now paused. Manual sends still allowed."
              end
    return if message.blank?

    Rails.logger.warn "[EmailCapNotification] #{message}"

    notify(User.where(company_id: company.id).where(role: %w[admin company_admin]).active,
           company, message, '/settings/communications', 'View Email Settings')

    notify(User.platform_admins.active, company, message, '/admin/email-usage', 'View Email Usage')
  end

  private

  def notify(users, company, message, action_url, action_text)
    users.each do |user|
      NotificationService.create(
        recipient:         user,
        notification_type: :email_cap_alert,
        message:           message,
        company_id:        company.id,
        action_url:        action_url,
        action_text:       action_text
      )
    end
  end
end
