# frozen_string_literal: true

class FiscalPeriod < ApplicationRecord
  belongs_to :company
  belongs_to :closed_by, class_name: 'User', optional: true

  STATUSES = %w[open closed locked].freeze

  validates :fiscal_year, presence: true
  validates :period_number, presence: true, uniqueness: { scope: [:company_id, :fiscal_year] }
  validates :start_date, presence: true
  validates :end_date, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :dates_are_contiguous

  scope :for_year, ->(year) { where(fiscal_year: year) }
  scope :open_periods, -> { where(status: 'open') }
  scope :ordered, -> { order(:fiscal_year, :period_number) }

  def open?
    status == 'open'
  end

  def closed?
    status == 'closed'
  end

  def locked?
    status == 'locked'
  end

  def close!(user)
    return unless open?
    update!(
      status: 'closed',
      closed_at: Time.current,
      closed_by: user
    )

    settings = company.accounting_settings
    if settings&.lock_period_on_close
      company.journal_entries
        .where(fiscal_year: fiscal_year, fiscal_period: period_number)
        .update_all(locked: true)
    end
  end

  def reopen!
    return unless closed?
    update!(status: 'open', closed_at: nil, closed_by: nil)

    company.journal_entries
      .where(fiscal_year: fiscal_year, fiscal_period: period_number)
      .update_all(locked: false)
  end

  def self.generate_for_year(company, year)
    settings = company.accounting_settings
    start_month = settings&.fiscal_year_start_month || 1

    12.times do |i|
      month = ((start_month - 1 + i) % 12) + 1
      period_year = (start_month > 1 && month < start_month) ? year + 1 : year
      start_date = Date.new(period_year, month, 1)
      end_date = start_date.end_of_month

      company.fiscal_periods.find_or_create_by!(
        fiscal_year: year,
        period_number: i + 1
      ) do |fp|
        fp.start_date = start_date
        fp.end_date = end_date
        fp.status = 'open'
      end
    end
  end

  private

  def dates_are_contiguous
    return unless start_date.present? && end_date.present?
    errors.add(:end_date, "must be after start date") if end_date <= start_date
  end
end
