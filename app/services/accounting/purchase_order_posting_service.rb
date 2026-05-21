# frozen_string_literal: true

module Accounting
  class PurchaseOrderPostingService
    def initialize(purchase_order)
      @po = purchase_order
      @company = purchase_order.company
    end

    def post!
      return unless should_post?
      return if already_posted?

      settings = AccountingSettings.for_company(@company)
      ap_account = settings.default_ap_account
      default_inventory_account = settings.default_parts_inventory_account

      unless ap_account && default_inventory_account
        Rails.logger.warn("[Accounting] Skipping PO #{@po.id} post — missing AP (#{ap_account&.id}) or Parts Inventory (#{default_inventory_account&.id}) account")
        return nil
      end

      lines_data = build_lines(default_inventory_account)
      return nil if lines_data.empty?

      total = lines_data.sum { |l| l[:debit_amount] }
      return nil if total <= 0

      ActiveRecord::Base.transaction do
        je = @company.journal_entries.build(
          entry_date: @po.received_date || @po.try(:expected_delivery_date) || Date.current,
          memo: "PO #{@po.po_number} — #{po_supplier_name}",
          source_type: 'auto',
          source_entity: @po,
          posted_by_id: @po.try(:approved_by_id) || @po.try(:created_by_id)
        )

        lines_data.each do |line|
          je.journal_entry_lines.build(
            chart_of_account_id: line[:chart_of_account_id],
            debit_amount: line[:debit_amount],
            credit_amount: 0,
            memo: line[:memo],
            location_id: @po.try(:location_id) || Current.location_id,
            department: 'parts'
          )
        end

        je.journal_entry_lines.build(
          chart_of_account: ap_account,
          debit_amount: 0,
          credit_amount: total,
          memo: "AP — PO #{@po.po_number}",
          location_id: @po.try(:location_id) || Current.location_id,
          department: 'parts'
        )

        unless je.save
          Rails.logger.error("[Accounting] Failed to post PO #{@po.id}: #{je.errors.full_messages.join(', ')}")
          raise ActiveRecord::Rollback
        end

        Rails.logger.info("[Accounting] Posted PO #{@po.id} → JE #{je.entry_number}")
        je
      end
    end

    private

    def should_post?
      settings = AccountingSettings.for_company(@company)
      settings&.auto_post_purchase_orders
    end

    def already_posted?
      @company.journal_entries.where(
        source_entity_type: 'PurchaseOrder',
        source_entity_id: @po.id,
        is_void: false
      ).exists?
    end

    def build_lines(default_inventory_account)
      lines = (@po.try(:purchase_order_lines) || []).map do |line|
        next if line.try(:line_total).to_f <= 0 && line.try(:quantity_received).to_f <= 0

        amount = line.try(:line_total) ||
                 ((line.try(:quantity_received) || line.try(:quantity_ordered) || 0) *
                  (line.try(:unit_cost) || 0))
        next if amount.to_f <= 0

        part = line.try(:part)
        account = Accounting::AccountLinkResolver.resolve(
          company: @company,
          entity: part,
          purpose: 'inventory'
        ) || default_inventory_account

        {
          chart_of_account_id: account.id,
          debit_amount: BigDecimal(amount.to_s),
          memo: "PO #{@po.po_number} — #{part&.try(:name) || line.try(:description) || "Line #{line.try(:line_number)}"}"
        }
      end.compact

      if lines.empty? && @po.total_amount.to_f > 0
        lines << {
          chart_of_account_id: default_inventory_account.id,
          debit_amount: BigDecimal(@po.total_amount.to_s),
          memo: "PO #{@po.po_number}"
        }
      end

      lines
    end

    def po_supplier_name
      @po.try(:supplier)&.name || 'Vendor'
    end
  end
end
