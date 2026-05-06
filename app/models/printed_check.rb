# frozen_string_literal: true

class PrintedCheck < ApplicationRecord
  belongs_to :company
  belongs_to :bank_account
  belongs_to :journal_entry, optional: true
  belongs_to :contact, optional: true

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
    update!(status: STATUS_VOIDED)
    journal_entry&.void!(Current.user) if journal_entry && !journal_entry.is_void?
  end

  private

  def check_number_unique
    return unless check_number.present?

    exists = PrintedCheck.where(bank_account_id: bank_account_id, check_number: check_number)
    exists = exists.where.not(id: id) if persisted?

    errors.add(:check_number, 'has already been used') if exists.exists?
  end
end
