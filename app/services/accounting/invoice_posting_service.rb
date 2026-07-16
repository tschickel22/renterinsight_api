# frozen_string_literal: true

module Accounting
  class InvoicePostingService
    def initialize(invoice)
      @invoice = invoice
      @company = invoice.company
    end

    def post!
      return unless should_post?
      return if already_posted?

      settings = AccountingSettings.for_company(@company)
      ar_account = settings.default_ar_account
      tax_account = settings.default_sales_tax_payable_account

      unless ar_account
        Rails.logger.warn("[Accounting] Skipping invoice #{@invoice.id} post — no AR account configured")
        return
      end

      # Every GL line for this invoice must post to the invoice's own location.
      # Falling back to Current.location_id would silently attribute revenue to
      # whichever location the actor happens to have selected — wrong for reports.
      location_id = @invoice.location_id
      unless location_id.present?
        Rails.logger.error("[Accounting] Cannot post invoice #{@invoice.id} — no location_id on invoice")
        return
      end

      ActiveRecord::Base.transaction do
        je = @company.journal_entries.build(
          entry_date: @invoice.invoice_date || @invoice.created_at.to_date,
          memo: "Invoice #{@invoice.invoice_number} — #{invoice_contact_name}",
          source_type: 'auto',
          source_entity: @invoice,
          posted_by_id: @invoice.try(:created_by_id)
        )

        subtotal = @invoice.subtotal || (@invoice.invoice_items.sum(:amount) rescue BigDecimal('0'))
        tax_amount = @invoice.tax_amount || BigDecimal('0')
        invoice_total = subtotal + tax_amount

        if invoice_total > 0
          je.journal_entry_lines.build(
            chart_of_account: ar_account,
            debit_amount: invoice_total,
            credit_amount: 0,
            memo: "Invoice #{@invoice.invoice_number}",
            location_id: location_id,
            contact_id: @invoice.try(:contact_id) || @invoice.try(:customer_id)
          )
        end

        revenue_lines = build_revenue_lines
        revenue_lines.each do |revenue_account_id, line_data|
          je.journal_entry_lines.build(
            chart_of_account_id: revenue_account_id,
            debit_amount: 0,
            credit_amount: line_data[:amount],
            memo: line_data[:memo],
            location_id: location_id,
            department: line_data[:department],
            deal_id: line_data[:deal_id],
            vehicle_id: line_data[:vehicle_id],
            contact_id: @invoice.try(:contact_id) || @invoice.try(:customer_id)
          )
        end

        # Prefer per-TaxCode credit lines so state/county/city/etc post to
        # their configured liability accounts. Falls back to a single lump
        # credit to the default tax-payable account when the invoice has no
        # snapshots (legacy tax_rate path or no TaxCodes configured).
        tax_buckets = tax_credit_buckets(default_account: tax_account)
        tax_buckets.each do |account, breakdown|
          je.journal_entry_lines.build(
            chart_of_account: account,
            debit_amount: 0,
            credit_amount: breakdown[:amount],
            memo: breakdown[:memo],
            location_id: location_id
          )
        end

        unless je.save
          Rails.logger.error("[Accounting] Failed to post invoice #{@invoice.id}: #{je.errors.full_messages.join(', ')}")
          raise ActiveRecord::Rollback
        end

        Rails.logger.info("[Accounting] Posted invoice #{@invoice.id} → JE #{je.entry_number}")
        je
      end
    end

    private

    def should_post?
      settings = AccountingSettings.for_company(@company)
      settings&.auto_post_invoices
    end

    def already_posted?
      @company.journal_entries.where(
        source_entity_type: 'Invoice',
        source_entity_id: @invoice.id,
        is_void: false
      ).exists?
    end

    def invoice_contact_name
      if @invoice.respond_to?(:contact) && @invoice.contact
        "#{@invoice.contact.try(:first_name)} #{@invoice.contact.try(:last_name)}".strip
      elsif @invoice.respond_to?(:customer_name)
        @invoice.customer_name
      else
        "Customer"
      end
    end

    # Groups tax credit lines by chart_of_account. When invoice line items
    # have TaxCode snapshots, each snapshot's tax_code.chart_of_account_id
    # decides the bucket; otherwise everything falls into a single bucket
    # against the company's default sales-tax-payable account.
    def tax_credit_buckets(default_account:)
      snapshots = InvoiceItemTax.includes(:tax_code)
                                .joins(:invoice_item)
                                .where(invoice_items: { invoice_id: @invoice.id })

      # No per-line snapshots — fall back to the invoice's aggregate tax_amount
      # posted to the default liability account.
      if snapshots.none?
        tax_amount = @invoice.tax_amount || BigDecimal('0')
        return {} unless tax_amount > 0 && default_account
        return {
          default_account => {
            amount: tax_amount,
            memo:   "Sales tax — Invoice #{@invoice.invoice_number}"
          }
        }
      end

      buckets = {}
      snapshots.each do |snap|
        account = snap.tax_code.chart_of_account || default_account
        next unless account

        buckets[account] ||= { amount: BigDecimal('0'), memo_parts: [] }
        buckets[account][:amount] += snap.computed_amount
        buckets[account][:memo_parts] << snap.tax_code.name
      end

      buckets.each_value do |b|
        b[:memo] = "Sales tax (#{b[:memo_parts].uniq.first(3).join(', ')}) — Invoice #{@invoice.invoice_number}"
        b.delete(:memo_parts)
      end

      buckets.reject { |_acct, b| b[:amount] <= 0 }
    end

    def build_revenue_lines
      settings = AccountingSettings.for_company(@company)
      default_revenue = settings.default_sales_revenue_account

      grouped = {}

      if @invoice.respond_to?(:invoice_items) && @invoice.invoice_items.any?
        @invoice.invoice_items.each do |item|
          entity = item.try(:vehicle) || item.try(:service_ticket) || item
          revenue_account = AccountLinkResolver.resolve(
            company: @company,
            entity: entity,
            purpose: 'revenue'
          ) || default_revenue

          next unless revenue_account

          account_id = revenue_account.id
          grouped[account_id] ||= { amount: BigDecimal('0'), memo: [], department: nil, deal_id: nil, vehicle_id: nil }
          grouped[account_id][:amount] += (item.try(:total) || item.try(:amount) || BigDecimal('0'))
          grouped[account_id][:memo] << item.try(:description)
          grouped[account_id][:deal_id] ||= item.try(:deal_id)
          grouped[account_id][:vehicle_id] ||= item.try(:vehicle_id)
        end
      else
        if default_revenue
          subtotal = @invoice.subtotal || @invoice.try(:total) || BigDecimal('0')
          tax = @invoice.try(:tax_amount) || BigDecimal('0')
          grouped[default_revenue.id] = {
            amount: subtotal - tax,
            memo: ["Invoice #{@invoice.invoice_number}"],
            department: nil,
            deal_id: @invoice.try(:deal_id),
            vehicle_id: @invoice.try(:vehicle_id)
          }
        end
      end

      grouped.each do |_id, data|
        data[:memo] = data[:memo].compact.uniq.first(3).join('; ')
      end

      grouped
    end
  end
end
