# frozen_string_literal: true

class BankReconciliation < ApplicationRecord
  belongs_to :company
  belongs_to :bank_account
  belongs_to :completed_by, class_name: 'User', optional: true

  has_many :bank_reconciliation_items, dependent: :destroy

  STATUSES = %w[in_progress completed].freeze

  validates :statement_date, presence: true
  validates :statement_ending_balance, presence: true
  validates :beginning_balance, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :no_overlapping_reconciliation
  validate :difference_must_be_zero_to_complete

  scope :in_progress, -> { where(status: 'in_progress') }
  scope :completed, -> { where(status: 'completed') }
  scope :ordered, -> { order(statement_date: :desc) }

  def in_progress?
    status == 'in_progress'
  end

  def completed?
    status == 'completed'
  end

  def recalculate!
    cleared_items = bank_reconciliation_items.where(cleared: true)

    self.cleared_deposits = cleared_items.where('amount > 0').sum(:amount)
    self.cleared_payments = cleared_items.where('amount < 0').sum(:amount).abs
    self.calculated_balance = beginning_balance + self.cleared_deposits - self.cleared_payments
    self.difference = statement_ending_balance - calculated_balance

    save!
  end

  def complete!(user)
    recalculate!

    unless difference.zero?
      errors.add(:base, "Cannot complete: difference is #{difference}")
      return false
    end

    update!(
      status: 'completed',
      completed_at: Time.current,
      completed_by: user
    )

    bank_reconciliation_items.where(cleared: true).update_all(
      cleared_date: statement_date
    )

    true
  end

  private

  def no_overlapping_reconciliation
    return unless statement_date.present?

    existing = company.bank_reconciliations
      .where(bank_account_id: bank_account_id, status: 'completed')
      .where('statement_date >= ?', statement_date)

    existing = existing.where.not(id: id) if persisted?

    if existing.exists?
      errors.add(:statement_date, "overlaps with an existing completed reconciliation")
    end
  end

  def difference_must_be_zero_to_complete
    if status == 'completed' && difference.present? && !difference.zero?
      errors.add(:base, "Difference must be zero to complete reconciliation")
    end
  end
end
