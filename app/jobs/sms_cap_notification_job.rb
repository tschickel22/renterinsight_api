# frozen_string_literal: true

class SmsCapNotificationJob < ApplicationJob
  queue_as :default

  def perform(company_id, threshold)
    company = Company.find_by(id: company_id)
    return unless company

    limit   = company.sms_monthly_limit
    current = SmsUsageLog.current_period_count(company)
    period  = SmsUsageLog.current_billing_period

    message = case threshold.to_sym
    when :approaching_cap
      "SMS usage alert for #{company.name}: #{current}/#{limit} messages used this month (#{period}). Approaching your limit."
    when :at_cap
      "SMS cap reached for #{company.name}: #{current}/#{limit} messages used this month (#{period}). Automated sequences are now paused. Manual sends still allowed."
    end

    Rails.logger.warn "[SmsCapNotification] #{message}"

    # Notify all company admins in-app
    admin_users = User.where(company_id: company.id)
                      .where(role: %w[admin company_admin])
                      .active
    admin_users.each do |admin|
      NotificationService.create(
        recipient:         admin,
        notification_type: :sms_cap_alert,
        message:           message,
        company_id:        company.id,
        action_url:        '/settings/communications',
        action_text:       'View SMS Settings'
      )
    end

    # Also notify platform admins
    platform_admins = User.platform_admins.active
    platform_admins.each do |pa|
      NotificationService.create(
        recipient:         pa,
        notification_type: :sms_cap_alert,
        message:           message,
        company_id:        company.id,
        action_url:        '/admin/sms-usage',
        action_text:       'View SMS Usage'
      )
    end
  end
end
