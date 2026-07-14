# frozen_string_literal: true

class CreditMemoItem < ApplicationRecord
  belongs_to :credit_memo
  belongs_to :itemable, polymorphic: true, optional: true

  validates :description, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :rate,     numericality: { greater_than_or_equal_to: 0 }

  before_validation :calculate_amount

  private

  def calculate_amount
    self.amount = (quantity || 1) * (rate || 0)
  end
end
