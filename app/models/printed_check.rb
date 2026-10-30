# frozen_string_literal: true

class PrintedCheck < ApplicationRecord
  belongs_to :company
  belongs_to :bank_account
  belongs_to :journal_entry, optional: true
  belongs_to :contact, optional: true
  belongs_to :vendor, optional: true
  belongs_to :bill, optional: true
  belongs_to :bill_payment, optional: true

  STATUS_QUEUED = 'queued'
  STATUS_PRINTED = 'printed'
  STATUS_VOIDED = 'voided'

  validates :paid_to, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :check_number, presence: true, if: :printed?
  validate :check_number_unique, if: :check_number_changed?

  scope :queued, -> { where(status: STATUS_QUEUED) }
  scope :printed, -> { where(status: STATUS_PRINTED) }
  scope :ordered, -> { order(created_at: :desc) }

  def printed?
    status == STATUS_PRINTED
  end

  def queued?
    status == STATUS_QUEUED
  end

  # The next number nobody has printed on this account. The account's
  # check_number holds the last one printed (print! writes it), or the
  # starting number someone typed in Settings before anything printed.
  def self.next_number_for(bank_account)
    used = where(bank_account_id: bank_account.id).where("check_number ~ '^[0-9]+$'").maximum(Arel.sql('check_number::bigint'))
    set = bank_account.check_number.to_i
    return (set.positive? ? set : 1001) unless used

    [used + 1, set].max
  end

  # Numbers in start...start+count already printed on this account.
  def self.taken_numbers(bank_account, start, count)
    where(bank_account_id: bank_account.id, check_number: (start...(start + count)).map(&:to_s)).pluck(:check_number).sort
  end

  def print!(check_number)
    update!(
      status: STATUS_PRINTED,
      check_number: check_number,
      printed_on: Date.current
    )

    if bank_account.check_number.to_i < check_number.to_i
      bank_account.update_column(:check_number, check_number.to_i)
    end
  end

  def void!
    voider = Current.user

    transaction do
      update!(status: STATUS_VOIDED)
      journal_entry&.void!(voider) if journal_entry && !journal_entry.is_void?

      # Cascade-void the linked bill payment (if this check was queued from a bill).
      if bill_payment.present? && !bill_payment.voided?
        bill_payment.update!(voided: true, voided_at: Time.current)
        bp_je = bill_payment.journal_entry
        bp_je.void!(voider) if bp_je && !bp_je.is_void?
        bill_payment.bill&.recalculate_balance!
      end
    end
  end

  private

  def check_number_unique
    return unless check_number.present?

    exists = PrintedCheck.where(bank_account_id: bank_account_id, check_number: check_number)
    exists = exists.where.not(id: id) if persisted?

    errors.add(:check_number, 'has already been used') if exists.exists?
  end
end
