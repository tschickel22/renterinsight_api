# frozen_string_literal: true

module Accounting
  class CommissionPostingService
    def initialize(commission)
      @commission = commission
      @company = commission.company
    end

    # DEBIT Commission Expense (6010), CREDIT Accrued Compensation (2020)
    def post_accrual!(user: nil)
      return if already_accrual_posted?

      commission_exp = @company.chart_of_accounts.find_by(account_number: '6010')
      accrued_comp = @company.chart_of_accounts.find_by(account_number: '2020')
      return { error: 'Missing commission GL accounts' } unless commission_exp && accrued_comp

      amount = @commission.try(:amount) || @commission.try(:total) || BigDecimal('0')
      return { error: 'No commission amount' } if amount <= 0

      posting_service = ManualPostingService.new(@company)
      je = posting_service.post_simple!(
        debit_account: commission_exp,
        credit_account: accrued_comp,
        amount: amount,
        memo: "Commission accrual — #{commission_description}",
        entry_date: Date.current,
        source_entity: @commission,
        deal_id: @commission.try(:deal_id),
        department: 'new_sales',
        posted_by: user
      )

      { success: true, journal_entry: je }
    end

    # DEBIT Accrued Compensation (2020), CREDIT Bank
    def post_payment!(user: nil)
      return if already_payment_posted?

      accrued_comp = @company.chart_of_accounts.find_by(account_number: '2020')
      bank = @company.chart_of_accounts.where(sub_type: 'bank', is_active: true).order(:account_number).first
      return { error: 'Missing GL accounts' } unless accrued_comp && bank

      amount = @commission.try(:amount) || @commission.try(:total) || BigDecimal('0')
      return { error: 'No commission amount' } if amount <= 0

      posting_service = ManualPostingService.new(@company)
      je = posting_service.post_simple!(
        debit_account: accrued_comp,
        credit_account: bank,
        amount: amount,
        memo: "Commission payment — #{commission_description}",
        entry_date: Date.current,
        source_entity: @commission,
        deal_id: @commission.try(:deal_id),
        posted_by: user
      )

      { success: true, journal_entry: je }
    end

    private

    def already_accrual_posted?
      @company.journal_entries.where(
        source_entity_type: 'Commission', source_entity_id: @commission.id, is_void: false
      ).where("memo ILIKE '%accrual%'").exists?
    end

    def already_payment_posted?
      @company.journal_entries.where(
        source_entity_type: 'Commission', source_entity_id: @commission.id, is_void: false
      ).where("memo ILIKE '%payment%'").exists?
    end

    def commission_description
      user = @commission.try(:user) || @commission.try(:sales_rep)
      name = user ? "#{user.try(:first_name)} #{user.try(:last_name)}".strip : "Rep"
      deal = @commission.try(:deal)
      deal_info = deal ? " — #{deal.try(:title) || deal.try(:name)}" : ""
      "#{name}#{deal_info}"
    end
  end
end
