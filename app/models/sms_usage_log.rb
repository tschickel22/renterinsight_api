# frozen_string_literal: true

class SmsUsageLog < ApplicationRecord
  belongs_to :company

  OUTBOUND_COST = 0.0079
  INBOUND_COST  = 0.0075

  validates :billing_period, presence: true,
            format: { with: /\A\d{4}-\d{2}\z/, message: 'must be in YYYY-MM format' }
  validates :direction, presence: true, inclusion: { in: %w[inbound outbound] }
  validates :source, presence: true, inclusion: { in: %w[manual sequence inbound] }

  scope :for_period, ->(period) { where(billing_period: period) }
  scope :current_period, -> { for_period(Time.current.strftime('%Y-%m')) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }

  def self.current_billing_period
    Time.current.strftime('%Y-%m')
  end

  # Log a single message and return the record
  def self.log!(company:, direction:, source:, communication_id: nil)
    cost = direction == 'outbound' ? OUTBOUND_COST : INBOUND_COST
    create!(
      company:          company,
      billing_period:   current_billing_period,
      direction:        direction,
      source:           source,
      message_count:    1,
      twilio_cost:      cost,
      communication_id: communication_id
    )
  end

  # Total messages sent/received by a company in the current billing period
  def self.current_period_count(company)
    for_company(company.id).current_period.sum(:message_count)
  end

  # Cost breakdown for admin dashboard
  def self.period_summary(company, billing_period)
    records = for_company(company.id).for_period(billing_period)
    {
      total_messages: records.sum(:message_count),
      total_cost:     records.sum(:twilio_cost).to_f.round(4),
      outbound:       records.where(direction: 'outbound').sum(:message_count),
      inbound:        records.where(direction: 'inbound').sum(:message_count),
      manual:         records.where(source: 'manual').sum(:message_count),
      sequence:       records.where(source: 'sequence').sum(:message_count)
    }
  end
end
