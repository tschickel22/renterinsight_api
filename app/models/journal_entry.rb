# frozen_string_literal: true

class JournalEntry < ApplicationRecord
  belongs_to :company
  belongs_to :posted_by, class_name: 'User', optional: true
  belongs_to :voided_by, class_name: 'User', optional: true
  belongs_to :reversed_by, class_name: 'JournalEntry', optional: true
  belongs_to :source_entity, polymorphic: true, optional: true

  has_many :journal_entry_lines, dependent: :destroy
  accepts_nested_attributes_for :journal_entry_lines, allow_destroy: true

  validates :entry_date, presence: true
  validate :lines_balance
  validate :at_least_two_lines
  validate :no_edits_if_locked
  validate :no_edits_if_voided

  before_create :assign_entry_number
  before_save :set_fiscal_period

  scope :posted, -> { where(is_void: false) }
  scope :voided, -> { where(is_void: true) }
  scope :manual, -> { where(source_type: 'manual') }
  scope :for_period, ->(year, period) { where(fiscal_year: year, fiscal_period: period) }
  scope :for_date_range, ->(start_date, end_date) { where(entry_date: start_date..end_date) }

  def lines_balance
    return if journal_entry_lines.empty?

    total_debits = journal_entry_lines.reject(&:marked_for_destruction?).sum(&:debit_amount)
    total_credits = journal_entry_lines.reject(&:marked_for_destruction?).sum(&:credit_amount)

    unless total_debits == total_credits
      errors.add(:base, "Debit and Credit amounts must be equal (debits: #{total_debits}, credits: #{total_credits})")
    end
  end

  def at_least_two_lines
    active_lines = journal_entry_lines.reject(&:marked_for_destruction?)
    if active_lines.length < 2
      errors.add(:base, "Journal entry must have at least two lines")
    end
  end

  def no_edits_if_locked
    if locked && changed? && !new_record? && !is_void_changed?
      errors.add(:base, "Cannot edit a locked journal entry (period is closed)")
    end
  end

  def no_edits_if_voided
    if is_void && changed? && !is_void_changed?
      errors.add(:base, "Cannot edit a voided journal entry")
    end
  end

  def assign_entry_number
    return if entry_number.present?
    max = company.journal_entries.maximum(:entry_number).to_i
    self.entry_number = (max + 1).to_s.rjust(6, '0')
  end

  def set_fiscal_period
    return unless entry_date.present?
    settings = company.accounting_settings
    start_month = settings&.fiscal_year_start_month || 1

    if entry_date.month >= start_month
      self.fiscal_year = entry_date.year
      self.fiscal_period = entry_date.month - start_month + 1
    else
      self.fiscal_year = entry_date.year - 1
      self.fiscal_period = 12 - start_month + entry_date.month + 1
    end
  end

  def void!(user)
    return if is_void?

    transaction do
      reversing = company.journal_entries.build(
        entry_date: Date.current,
        memo: "VOID: #{memo}",
        source_type: 'auto',
        source_entity: source_entity,
        posted_by: user,
        locked: true  # Reversing entries can't be edited or voided
      )

      journal_entry_lines.each do |line|
        reversing.journal_entry_lines.build(
          chart_of_account_id: line.chart_of_account_id,
          debit_amount: line.credit_amount,
          credit_amount: line.debit_amount,
          memo: "VOID: #{line.memo}",
          location_id: line.location_id,
          department: line.department,
          contact_id: line.contact_id,
          deal_id: line.deal_id,
          vehicle_id: line.vehicle_id
        )
      end

      reversing.save!

      update!(
        is_void: true,
        voided_at: Time.current,
        voided_by: user,
        reversed_by: reversing
      )
    end
  end

  def total_debits
    journal_entry_lines.sum(:debit_amount)
  end

  def total_credits
    journal_entry_lines.sum(:credit_amount)
  end
end
