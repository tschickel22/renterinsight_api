# frozen_string_literal: true

class BudgetLine < ApplicationRecord
  belongs_to :budget
  belongs_to :chart_of_account

  delegate :company, to: :budget

  validates :chart_of_account_id, uniqueness: { scope: :budget_id }

  before_save :compute_annual_total

  def month_amounts
    (1..12).each_with_object({}) { |m, h| h[m] = month_amount(m) }
  end

  def month_amount(month)
    raise ArgumentError, "month must be 1..12" unless (1..12).cover?(month)
    public_send("month_#{month}")
  end

  def set_month_amount(month, value)
    raise ArgumentError, "month must be 1..12" unless (1..12).cover?(month)
    public_send("month_#{month}=", value)
  end

  private

  def compute_annual_total
    self.annual_total = (
      month_1.to_d + month_2.to_d + month_3.to_d + month_4.to_d +
      month_5.to_d + month_6.to_d + month_7.to_d + month_8.to_d +
      month_9.to_d + month_10.to_d + month_11.to_d + month_12.to_d
    ).round(2)
  end
end
