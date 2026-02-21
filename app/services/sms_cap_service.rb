# frozen_string_literal: true

class SmsCapService
  class CapExceededError < StandardError; end

  # Check cap before sending. Raises CapExceededError for sequence sends.
  # Returns :over_cap (but allows send) for manual sends — caller decides how to handle.
  def self.check!(company:, source:)
    limit = company.sms_monthly_limit
    return :unlimited if limit <= 0  # 0 means unlimited

    current = SmsUsageLog.current_period_count(company)
    usage_pct = (current.to_f / limit * 100).round

    Rails.logger.info "[SmsCapService] Company #{company.id}: #{current}/#{limit} messages (#{usage_pct}%)"

    # Fire notification jobs at thresholds (async, non-blocking)
    if usage_pct >= 100 && (usage_pct - 1) < 100
      SmsCapNotificationJob.perform_later(company.id, :at_cap)
    elsif usage_pct >= 80 && (usage_pct - 1) < 80
      SmsCapNotificationJob.perform_later(company.id, :approaching_cap)
    end

    if current >= limit
      if source == 'sequence'
        raise CapExceededError, "SMS cap reached (#{current}/#{limit}). Automated sequence SMS blocked."
      else
        # Manual sends: warn but allow
        Rails.logger.warn "[SmsCapService] Company #{company.id} over cap — manual send allowed"
        return :over_cap
      end
    end

    :ok
  end
end
