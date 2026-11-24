# frozen_string_literal: true

# A one-off change to what one person earns on one deal (a spiff, or a
# manager's correction), with the reason. The commission engine adds it to that
# person's lines, so the worksheet and the payment show it like any other line.
class CommissionAdjustment < ApplicationRecord
  belongs_to :company
  belongs_to :deal
  belongs_to :payee, class_name: 'User', foreign_key: :payee_user_id
  belongs_to :created_by, class_name: 'User', foreign_key: :created_by_user_id, optional: true

  scope :active, -> { where(is_deleted: false) }

  validates :amount, presence: true, numericality: { other_than: 0 }
  validates :reason, presence: true, length: { maximum: 255 }
  validate :payee_in_company

  private

  def payee_in_company
    errors.add(:payee_user_id, 'must be someone in this company') if payee && payee.company_id != company_id
  end
end
