# frozen_string_literal: true

class RecurringJournalEntry < ApplicationRecord
  belongs_to :company

  FREQUENCIES = %w[daily weekly monthly quarterly yearly].freeze

  validates :name, presence: true
  validates :frequency, presence: true, inclusion: { in: FREQUENCIES }
  validates :next_run_date, presence: true, if: :is_active?

  scope :active, -> { where(is_active: true) }
  scope :due, -> { where('next_run_date <= ?', Date.current) }

  attr_reader :last_error

  # template_lines format:
  # [
  #   { chart_of_account_id: 1, debit_amount: 100.00, credit_amount: 0, memo: "Rent", department: "admin" },
  #   { chart_of_account_id: 2, debit_amount: 0, credit_amount: 100.00, memo: "Rent", department: "admin" }
  # ]

  # `force: true` skips the date check — used by the "Generate now" UI button.
  # The scheduled job that runs hourly/daily still calls without force.
  def generate_entry!(force: false)
    return false_with_reason(:inactive, 'Template is inactive') unless is_active?
    return false_with_reason(:no_template_lines, 'Template has no lines') if (template_lines || []).empty?
    unless force || next_run_date <= Date.current
      return false_with_reason(:not_due,
        "Not due until #{next_run_date.strftime('%b %-d, %Y')}",
        next_run_date: next_run_date)
    end

    entry_date = force && next_run_date > Date.current ? Date.current : next_run_date

    je = company.journal_entries.build(
      entry_date: entry_date,
      memo: memo.presence || "Recurring: #{name}",
      source_type: 'recurring'
    )

    template_lines.each do |line|
      je.journal_entry_lines.build(
        chart_of_account_id: line['chart_of_account_id'],
        debit_amount: line['debit_amount'] || 0,
        credit_amount: line['credit_amount'] || 0,
        memo: line['memo'],
        department: line['department'],
        location_id: line['location_id']
      )
    end

    if je.save
      advance_next_run_date!
      update!(last_run_at: Time.current)
      je
    else
      Rails.logger.error("[RecurringJE] Failed to generate entry for #{id}: #{je.errors.full_messages}")
      false_with_reason(:invalid, je.errors.full_messages.join(', '))
    end
  end

  private

  def false_with_reason(code, message, **extra)
    @last_error = { code: code.to_s, message: message, **extra }
    nil
  end

  def advance_next_run_date!
    new_date = case frequency
               when 'daily' then next_run_date + 1.day
               when 'weekly' then next_run_date + 1.week
               when 'monthly' then next_run_date + 1.month
               when 'quarterly' then next_run_date + 3.months
               when 'yearly' then next_run_date + 1.year
               end

    if end_date.present? && new_date > end_date
      update!(is_active: false, next_run_date: nil)
    else
      update!(next_run_date: new_date)
    end
  end
end
