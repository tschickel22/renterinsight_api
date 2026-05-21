# frozen_string_literal: true

module Accounting
  # Posts a parts-consumption JE: DEBIT COGS, CREDIT Parts Inventory.
  #
  # Accepts any source_entity that exposes (via #try):
  #   - part_id           (or :part returning a Part)
  #   - quantity          (positive number consumed; defaults to 1)
  #   - unit_cost         (optional; falls back to Part#average_cost)
  #   - location_id       (optional)
  #
  # Typical sources: InventoryTransaction (transaction_type: 'usage'/'adjustment'),
  # ServiceTicket-related parts records, or a plain OpenStruct passed by a controller.
  class PartsUsagePostingService
    def initialize(source_entity, company: nil, department: 'parts')
      @source = source_entity
      @company = company || source_entity.try(:company) || raise(ArgumentError, "company required")
      @department = department
    end

    def post!
      return unless should_post?
      return if already_posted?

      settings = AccountingSettings.for_company(@company)
      cogs_account = settings.default_cogs_account
      inventory_account = settings.default_parts_inventory_account

      unless cogs_account && inventory_account
        Rails.logger.warn("[Accounting] Skipping parts usage #{source_label} — missing COGS or Parts Inventory account")
        return nil
      end

      part = resolve_part
      quantity = (@source.try(:quantity) || 1).to_d.abs
      unit_cost = (@source.try(:unit_cost) || part&.try(:average_cost) || 0).to_d
      total_cost = (quantity * unit_cost).round(2)
      return nil if total_cost <= 0

      ActiveRecord::Base.transaction do
        je = @company.journal_entries.build(
          entry_date: @source.try(:transaction_date) || Date.current,
          memo: "Parts usage — #{part&.try(:name) || source_label}",
          source_type: 'auto',
          source_entity: @source
        )

        je.journal_entry_lines.build(
          chart_of_account: cogs_account,
          debit_amount: total_cost,
          credit_amount: 0,
          memo: "COGS — #{part&.try(:name) || source_label}",
          location_id: @source.try(:location_id) || Current.location_id,
          department: @department
        )

        je.journal_entry_lines.build(
          chart_of_account: inventory_account,
          debit_amount: 0,
          credit_amount: total_cost,
          memo: "Inventory relief — #{part&.try(:name) || source_label}",
          location_id: @source.try(:location_id) || Current.location_id,
          department: @department
        )

        unless je.save
          Rails.logger.error("[Accounting] Failed to post parts usage #{source_label}: #{je.errors.full_messages.join(', ')}")
          raise ActiveRecord::Rollback
        end

        Rails.logger.info("[Accounting] Posted parts usage #{source_label} → JE #{je.entry_number}")
        je
      end
    end

    private

    def should_post?
      settings = AccountingSettings.for_company(@company)
      settings&.auto_post_parts_usage
    end

    def already_posted?
      @company.journal_entries.where(
        source_entity_type: @source.class.name,
        source_entity_id: @source.id,
        is_void: false
      ).where("memo ILIKE 'Parts usage%'").exists?
    end

    def resolve_part
      @source.try(:part) ||
        (@source.try(:part_id) && Part.find_by(id: @source.part_id))
    end

    def source_label
      "#{@source.class.name}##{@source.try(:id)}"
    end
  end
end
