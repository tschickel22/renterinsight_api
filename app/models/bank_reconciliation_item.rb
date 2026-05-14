# frozen_string_literal: true

class BankReconciliationItem < ApplicationRecord
  belongs_to :bank_reconciliation
  belongs_to :journal_entry_line

  validates :amount, presence: true

  scope :cleared, -> { where(cleared: true) }
  scope :uncleared, -> { where(cleared: false) }

  def toggle_cleared!
    update!(cleared: !cleared)
    bank_reconciliation.recalculate!
  end
end
