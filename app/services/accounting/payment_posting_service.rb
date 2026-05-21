# frozen_string_literal: true

module Accounting
  class PaymentPostingService
    def initialize(payment)
      @payment = payment
      @company = payment.company
    end

    def post!
      return unless should_post?
      return if already_posted?

      settings = AccountingSettings.for_company(@company)
      ar_account = settings.default_ar_account
      bank_gl_account = resolve_bank_account(settings)

      unless ar_account && bank_gl_account
        Rails.logger.warn("[Accounting] Skipping payment #{@payment.id} post — missing AR (#{ar_account&.id}) or bank (#{bank_gl_account&.id}) account")
        return
      end

      payment_amount = @payment.amount || @payment.try(:total) || BigDecimal('0')
      return if payment_amount <= 0

      ActiveRecord::Base.transaction do
        je = @company.journal_entries.build(
          entry_date: @payment.try(:payment_date) || @payment.try(:paid_at)&.to_date || @payment.created_at.to_date,
          memo: "Payment #{@payment.try(:payment_number) || @payment.id} — #{payment_contact_name}",
          source_type: 'auto',
          source_entity: @payment,
          posted_by_id: @payment.try(:received_by_id) || @payment.try(:created_by_id)
        )

        je.journal_entry_lines.build(
          chart_of_account: bank_gl_account,
          debit_amount: payment_amount,
          credit_amount: 0,
          memo: "Payment received",
          location_id: @payment.try(:location_id) || Current.location_id,
          contact_id: resolve_contact_id
        )

        je.journal_entry_lines.build(
          chart_of_account: ar_account,
          debit_amount: 0,
          credit_amount: payment_amount,
          memo: "Payment applied",
          location_id: @payment.try(:location_id) || Current.location_id,
          contact_id: resolve_contact_id,
          deal_id: @payment.try(:deal_id)
        )

        unless je.save
          Rails.logger.error("[Accounting] Failed to post payment #{@payment.id}: #{je.errors.full_messages.join(', ')}")
          raise ActiveRecord::Rollback
        end

        Rails.logger.info("[Accounting] Posted payment #{@payment.id} → JE #{je.entry_number}")
        je
      end
    end

    def post_refund!
      return if already_refund_posted?

      settings = AccountingSettings.for_company(@company)
      ar_account = settings.default_ar_account
      bank_gl_account = resolve_bank_account(settings)

      return unless ar_account && bank_gl_account

      refund_amount = @payment.amount || BigDecimal('0')
      return if refund_amount <= 0

      ActiveRecord::Base.transaction do
        je = @company.journal_entries.build(
          entry_date: Date.current,
          memo: "REFUND: Payment #{@payment.try(:payment_number) || @payment.id}",
          source_type: 'auto',
          source_entity: @payment
        )

        je.journal_entry_lines.build(
          chart_of_account: ar_account,
          debit_amount: refund_amount,
          credit_amount: 0,
          memo: "Payment refund",
          location_id: @payment.try(:location_id) || Current.location_id,
          contact_id: resolve_contact_id
        )

        je.journal_entry_lines.build(
          chart_of_account: bank_gl_account,
          debit_amount: 0,
          credit_amount: refund_amount,
          memo: "Payment refund",
          location_id: @payment.try(:location_id) || Current.location_id,
          contact_id: resolve_contact_id
        )

        je.save!
        Rails.logger.info("[Accounting] Posted refund for payment #{@payment.id} → JE #{je.entry_number}")
        je
      end
    end

    private

    def should_post?
      settings = AccountingSettings.for_company(@company)
      settings&.auto_post_payments
    end

    def already_posted?
      @company.journal_entries.where(
        source_entity_type: 'Payment',
        source_entity_id: @payment.id,
        is_void: false
      ).where.not("memo LIKE 'REFUND:%'").exists?
    end

    def already_refund_posted?
      @company.journal_entries.where(
        source_entity_type: 'Payment',
        source_entity_id: @payment.id,
        is_void: false
      ).where("memo LIKE 'REFUND:%'").exists?
    end

    def resolve_bank_account(settings)
      if @payment.respond_to?(:bank_account) && @payment.bank_account
        ba = @payment.bank_account
        @company.chart_of_accounts.find_by(bank_account_id: ba.id) ||
          settings.default_bank_account&.then { |dba| @company.chart_of_accounts.find_by(bank_account_id: dba.id) }
      else
        @company.chart_of_accounts.where(sub_type: 'bank', is_active: true).order(:account_number).first
      end
    end

    def resolve_contact_id
      @payment.try(:contact_id) || @payment.try(:customer_id)
    end

    def payment_contact_name
      if @payment.respond_to?(:contact) && @payment.contact
        "#{@payment.contact.try(:first_name)} #{@payment.contact.try(:last_name)}".strip
      elsif @payment.respond_to?(:customer_name)
        @payment.customer_name
      else
        "Customer"
      end
    end
  end
end
