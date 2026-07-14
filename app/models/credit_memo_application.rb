# frozen_string_literal: true

# Records how much of a CreditMemo is applied to a specific target (Invoice
# today). Mirrors PaymentApplication's shape — the sum of applications on a
# credit memo can't exceed the memo's total, and the applicable must belong
# to the same company as the memo.
class CreditMemoApplication < ApplicationRecord
  belongs_to :company
  belongs_to :credit_memo
  belongs_to :applicable, polymorphic: true
  belongs_to :created_by, class_name: 'User', optional: true

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :applied_at, presence: true
  validates :applicable_type, presence: true
  validates :applicable_id,   presence: true
  validate  :within_memo_remaining
  validate  :company_matches_credit_memo
  validate  :company_matches_applicable
  validate  :credit_memo_is_issued

  before_validation :set_defaults, on: :create
  after_commit :refresh_credit_memo_and_target, on: %i[create update destroy]

  private

  def set_defaults
    self.applied_at ||= Time.current
    self.company_id ||= credit_memo&.company_id
  end

  def within_memo_remaining
    return unless credit_memo && amount

    other = credit_memo.credit_memo_applications
    other = other.where.not(id: id) if persisted?
    already = other.sum(:amount) || 0

    if already + amount > credit_memo.total
      errors.add(:amount, "would exceed credit memo total (#{credit_memo.total}); #{already} is already applied")
    end
  end

  def company_matches_credit_memo
    return unless credit_memo && company_id
    errors.add(:company_id, 'must match the credit memo company') if company_id != credit_memo.company_id
  end

  def company_matches_applicable
    return unless applicable && company_id
    target_company = applicable.try(:company_id)
    return if target_company.nil?
    errors.add(:applicable, 'must belong to the same company as the credit memo') if target_company != company_id
  end

  def credit_memo_is_issued
    return unless credit_memo
    return if credit_memo.status.in?(%w[issued partial])
    errors.add(:credit_memo, "must be issued before applying (is #{credit_memo.status})")
  end

  def refresh_credit_memo_and_target
    credit_memo&.refresh_applied_totals!
    if applicable.respond_to?(:update_status_based_on_payments)
      applicable.update_status_based_on_payments
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
