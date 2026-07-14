# frozen_string_literal: true

# Records how much of a Payment goes toward a specific target (Invoice today,
# CreditMemo/Loan later). Sum of a payment's applications cannot exceed the
# payment amount — the leftover is treated as unapplied credit.
class PaymentApplication < ApplicationRecord
  belongs_to :company
  belongs_to :payment
  belongs_to :applicable, polymorphic: true
  belongs_to :created_by, class_name: 'User', optional: true

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :applied_at, presence: true
  validates :applicable_type, presence: true
  validates :applicable_id, presence: true
  validate  :total_applied_does_not_exceed_payment
  validate  :company_matches_payment
  validate  :company_matches_applicable

  before_validation :set_defaults, on: :create
  after_commit      :refresh_applicable_paid_state, on: %i[create update destroy]

  scope :for_applicable, ->(target) {
    where(applicable_type: target.class.base_class.name, applicable_id: target.id)
  }

  private

  def set_defaults
    self.applied_at ||= Time.current
    self.company_id ||= payment&.company_id
  end

  def total_applied_does_not_exceed_payment
    return unless payment && amount

    other = payment.payment_applications
    other = other.where.not(id: id) if persisted?
    already = other.sum(:amount) || 0

    if already + amount > payment.amount
      errors.add(
        :amount,
        "would exceed payment amount (#{payment.amount}); #{already} is already applied"
      )
    end
  end

  def company_matches_payment
    return unless payment && company_id
    errors.add(:company_id, 'must match the payment company') if company_id != payment.company_id
  end

  def company_matches_applicable
    return unless applicable && company_id
    target_company = applicable.try(:company_id)
    return if target_company.nil?
    errors.add(:applicable, 'must belong to the same company as the payment') if target_company != company_id
  end

  # Ask the target to recompute its paid state directly — touch would only
  # fire after_touch, not after_save, so Invoice#update_status_based_on_payments
  # needs to be called explicitly.
  def refresh_applicable_paid_state
    return unless applicable.respond_to?(:update_status_based_on_payments)
    applicable.update_status_based_on_payments
  rescue ActiveRecord::RecordNotFound
    # Applicable was destroyed in the same transaction — nothing to refresh.
  end
end
