# frozen_string_literal: true

class BillLineItem < ApplicationRecord
  belongs_to :bill
  belongs_to :chart_of_account
  belongs_to :location, optional: true

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :chart_of_account_id, presence: true
end
