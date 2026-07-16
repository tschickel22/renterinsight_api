# frozen_string_literal: true

# A CreditMemo reduces what a customer owes without recording cash inflow.
# Once issued, its remaining balance can be applied to any of the customer's
# open invoices via CreditMemoApplication rows. Statuses:
#   - draft   : being built, no effect on customer balance
#   - issued  : active with unapplied balance
#   - partial : some applied but not fully consumed
#   - applied : fully consumed by applications
#   - voided  : reversed
class CreditMemo < ApplicationRecord
  belongs_to :company
  belongs_to :location
  belongs_to :contact,    optional: true
  belongs_to :source,     polymorphic: true, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  has_many :credit_memo_items,         dependent: :destroy
  has_many :credit_memo_applications,  dependent: :destroy
  accepts_nested_attributes_for :credit_memo_items, allow_destroy: true

  validates :credit_memo_number, presence: true, uniqueness: { scope: :company_id }
  validates :memo_date, presence: true
  validates :status, inclusion: { in: %w[draft issued partial applied voided] }
  validates :total, numericality: { greater_than_or_equal_to: 0 }

  before_validation :generate_number,    on: :create
  before_validation :set_default_status, on: :create
  before_save :calculate_totals
  after_save  :finalize_line_taxes_if_needed
  after_save  :sync_applied_state
  after_save  :notify_applicables_of_status_change, if: :saved_change_to_status?

  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  scope :active,      -> { not_deleted.where.not(status: 'voided') }
  scope :issued,      -> { not_deleted.where(status: %w[issued partial]) }

  # Advisory-lock namespace distinct from invoice / journal-entry generators.
  CREDIT_MEMO_NUMBER_LOCK_NAMESPACE = 0x1_2E_00_C4.freeze

  def issue!
    return if is_deleted?
    return unless draft?
    update!(status: 'issued')
  end

  def draft?;   status == 'draft';   end
  def voided?;  status == 'voided';  end
  def applied?; status == 'applied'; end

  # Convenience: apply this credit to an invoice, defaulting to whatever's
  # still unapplied on the memo.
  def apply_to!(target, amount: nil, applied_at: Time.current, created_by: nil)
    credit_memo_applications.create!(
      company_id: company_id,
      applicable: target,
      amount:     amount || amount_remaining,
      applied_at: applied_at,
      created_by: created_by
    )
  end

  # Called by CreditMemoApplication after_commit — recompute amount_applied /
  # amount_remaining / status from the current set of applications. Public so
  # callers can force a refresh if application rows change outside a callback.
  def refresh_applied_totals!
    return if is_deleted?

    with_lock do
      applied = credit_memo_applications.sum(:amount)
      remaining = (total || 0) - applied

      new_status =
        if voided?
          'voided'
        elsif applied >= (total || 0) && (total || 0) > 0
          'applied'
        elsif applied > 0
          'partial'
        elsif draft?
          'draft'
        else
          'issued'
        end

      update_columns(
        amount_applied:   applied,
        amount_remaining: remaining,
        status:           new_status
      )
    end
  end

  private

  def generate_number
    return if credit_memo_number.present?
    return unless company_id

    self.class.connection.execute(
      self.class.sanitize_sql_array(['SELECT pg_advisory_xact_lock(?, ?)',
                                     CREDIT_MEMO_NUMBER_LOCK_NAMESPACE, company_id])
    )

    prefix = 'CM'
    last = company.credit_memos.order(created_at: :desc).first
    next_number =
      if last&.credit_memo_number&.start_with?(prefix)
        last.credit_memo_number.gsub(/\D/, '').to_i + 1
      else
        1000
      end

    loop do
      candidate = "#{prefix}-#{next_number.to_s.rjust(6, '0')}"
      break self.credit_memo_number = candidate unless company.credit_memos.exists?(credit_memo_number: candidate)
      next_number += 1
    end
  end

  def set_default_status
    self.status ||= 'draft'
  end

  def calculate_totals
    return if is_deleted?

    self.subtotal   = credit_memo_items.sum(&:amount)
    self.tax_amount ||= 0
    self.total      = subtotal + tax_amount
    self.amount_applied   ||= 0
    self.amount_remaining = total - amount_applied
  end

  # Rebuild each line's tax snapshots against active TaxCodes, then
  # rewrite tax_amount / total / amount_remaining from the fresh values.
  # Only runs when the company has TaxCodes configured; without them the
  # legacy calculate_totals result stands.
  def finalize_line_taxes!
    return if is_deleted?
    credit_memo_items.reload.each(&:recompute_taxes!)

    new_tax   = credit_memo_items.reload.sum { |i| i.tax_amount }.round(2)
    new_total = (subtotal || 0) + new_tax
    new_rem   = new_total - (amount_applied || 0)
    update_columns(tax_amount: new_tax, total: new_total, amount_remaining: new_rem)
  end

  def finalize_line_taxes_if_needed
    return unless company&.tax_codes&.active&.exists?
    finalize_line_taxes!
  end

  def sync_applied_state
    # Skip on the initial create — applications will call refresh_applied_totals!
    # themselves after they save.
    return unless saved_change_to_total? || saved_change_to_amount_applied?
    refresh_applied_totals!
  rescue ActiveRecord::RecordNotFound
    nil
  end

  # Status changes (issue!, void, etc.) don't touch application rows, so
  # PaymentApplication-style callbacks won't fire. Push the recompute out to
  # every target this memo is applied against — voiding should retroactively
  # remove the credit from invoice.amount_credited, for instance.
  def notify_applicables_of_status_change
    credit_memo_applications.includes(:applicable).each do |app|
      next unless app.applicable.respond_to?(:update_status_based_on_payments)
      app.applicable.update_status_based_on_payments
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
