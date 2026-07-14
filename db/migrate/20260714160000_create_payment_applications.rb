# frozen_string_literal: true

# payment_applications is the join between a Payment and whatever it pays down —
# an Invoice today, a CreditMemo or Loan later. Replaces the 1:1 polymorphic
# payments.payable_type / payable_id, which can't express split payments (one
# payment across many invoices) or unapplied credit (payment amount not fully
# consumed by applications).
class CreatePaymentApplications < ActiveRecord::Migration[8.0]
  def change
    create_table :payment_applications do |t|
      t.references :company,   null: false, foreign_key: true
      t.references :payment,   null: false, foreign_key: true
      t.references :applicable, polymorphic: true, null: false
      t.decimal    :amount,     precision: 12, scale: 2, null: false
      t.datetime   :applied_at, null: false
      t.bigint     :created_by_id
      t.timestamps
    end

    # A given payment should only have one application row per target — if you
    # need to change how much of a payment goes to an invoice, adjust the
    # existing row's amount rather than adding a second row for the same pair.
    add_index :payment_applications,
              [:payment_id, :applicable_type, :applicable_id],
              unique: true,
              name: 'idx_payment_applications_unique_pair'

    # Fast "how much has this invoice been paid?" lookups.
    add_index :payment_applications,
              [:applicable_type, :applicable_id, :company_id],
              name: 'idx_payment_applications_by_target_and_company'
  end
end
