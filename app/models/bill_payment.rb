# frozen_string_literal: true

class BillPayment < ApplicationRecord
  belongs_to :bill
  belongs_to :company
  belongs_to :bank_account, optional: true
  belongs_to :chart_of_account, optional: true
  belongs_to :journal_entry, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :payment_date, presence: true

  PAYMENT_METHODS = %w[check ach credit_card cash other].freeze
  validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_blank: true
end
