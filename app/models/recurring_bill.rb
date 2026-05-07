# frozen_string_literal: true

class RecurringBill < ApplicationRecord
  belongs_to :company
  belongs_to :supplier, optional: true
  # Parallel association to the unified vendors table. New callers should use :vendor.
  belongs_to :vendor, optional: true
  belongs_to :contact, optional: true
  belongs_to :expense_account, class_name: 'ChartOfAccount'
  belongs_to :payment_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :location, optional: true

  FREQUENCIES = %w[monthly quarterly yearly].freeze
  POSTING_TYPES = %w[ap direct].freeze

  validates :name, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :frequency, presence: true, inclusion: { in: FREQUENCIES }
  validates :next_due_date, presence: true
  validates :posting_type, inclusion: { in: POSTING_TYPES }

  scope :active, -> { where(is_active: true) }
  scope :due, -> { where('next_due_date <= ?', Date.current) }
  scope :ordered, -> { order(:next_due_date) }

  def generate_entry!
    return unless is_active? && next_due_date <= Date.current

    settings = AccountingSettings.for_company(company)
    posting_service = Accounting::ManualPostingService.new(company)

    je = if posting_type == 'ap'
           ap_account = payment_account || settings.default_ap_account
           return { error: 'No AP account configured' } unless ap_account

           posting_service.post_simple!(
             debit_account: expense_account,
             credit_account: ap_account,
             amount: amount,
             memo: memo.presence || "Recurring: #{name}",
             entry_date: next_due_date,
             source_entity: self,
             location_id: location_id,
             department: department,
             contact_id: contact_id
           )
         else
           bank = company.chart_of_accounts.where(sub_type: 'bank', is_active: true).order(:account_number).first
           return { error: 'No bank account configured' } unless bank

           posting_service.post_simple!(
             debit_account: expense_account,
             credit_account: bank,
             amount: amount,
             memo: memo.presence || "Recurring: #{name}",
             entry_date: next_due_date,
             source_entity: self,
             location_id: location_id,
             department: department,
             contact_id: contact_id
           )
         end

    if je
      advance_next_due_date!
      update!(last_generated_at: Time.current, generated_count: (generated_count || 0) + 1)
      { success: true, journal_entry: je }
    else
      { error: 'Failed to generate entry' }
    end
  end

  private

  def advance_next_due_date!
    new_date = case frequency
               when 'monthly' then next_due_date + 1.month
               when 'quarterly' then next_due_date + 3.months
               when 'yearly' then next_due_date + 1.year
               end

    if end_date.present? && new_date > end_date
      update!(is_active: false, next_due_date: nil)
    else
      update!(next_due_date: new_date)
    end
  end
end
