# frozen_string_literal: true

# Monthly campaign email allowance, mirroring SmsCapService.
#
# Deliberately separate from Messaging::ThrottleChecker. That enforces RATE (per mailbox,
# per minute and hour, a deliverability concern that exists because Exchange Online blocked
# a mailbox for bursting). This enforces VOLUME (per company, per month, a billing
# concern). A tenant well under their monthly allowance still must not burst, and a tenant
# sending slowly can still exhaust a monthly plan.
class EmailCapService
  class CapExceededError < StandardError; end

  # Raises for automated campaign sends, warns and allows for manual ones. Automated sends
  # are the ones that can run away unattended, and they are the ones a tenant would rather
  # have paused than billed for.
  AUTOMATED_SOURCES = %w[campaign sequence automation].freeze

  def self.check!(company:, source:)
    new(company: company, source: source).check!
  end

  def self.current_period_count(company)
    CampaignSend.real
                .where(company_id: company.id)
                .where(sent_at: period_start..)
                .count
  end

  def self.period_start
    Time.current.beginning_of_month
  end

  def self.current_billing_period
    Time.current.strftime('%Y-%m')
  end

  def initialize(company:, source:)
    @company = company
    @source = source.to_s
  end

  def check!
    return :unlimited if limit <= 0 # 0 means unlimited

    Rails.logger.info "[EmailCapService] Company #{company.id}: #{current}/#{limit} emails (#{usage_pct}%)"

    notify_threshold_crossing

    if current >= limit
      if automated?
        raise CapExceededError,
              "Email cap reached (#{current}/#{limit}). Automated campaign email blocked."
      end

      Rails.logger.warn "[EmailCapService] Company #{company.id} over cap — manual send allowed"
      return :over_cap
    end

    :ok
  end

  private

  attr_reader :company, :source

  def automated?
    AUTOMATED_SOURCES.include?(source)
  end

  def limit
    @limit ||= company.email_monthly_limit.to_i
  end

  def current
    @current ||= self.class.current_period_count(company)
  end

  def usage_pct
    @usage_pct ||= (current.to_f / limit * 100).round
  end

  # Fires once as each threshold is crossed rather than on every send past it, using the
  # same "did the previous send sit below this line" test as SmsCapService.
  def notify_threshold_crossing
    if usage_pct >= 100 && previous_pct < 100
      EmailCapNotificationJob.perform_later(company.id, :at_cap)
    elsif usage_pct >= 80 && previous_pct < 80
      EmailCapNotificationJob.perform_later(company.id, :approaching_cap)
    end
  end

  def previous_pct
    ((current - 1).to_f / limit * 100).round
  end
end
