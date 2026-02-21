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

    # TODO: wire up email notification to company billing contact and platform admin
    # For now this logs the event — email delivery will be added when notification
    # system is extended in a future run
  end
end
