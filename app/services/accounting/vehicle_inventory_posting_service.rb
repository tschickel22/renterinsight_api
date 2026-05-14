# frozen_string_literal: true

module Accounting
  # Posts the BUY/RECEIVE side for a vehicle entering inventory.
  # DEBIT Vehicle Inventory, CREDIT Accounts Payable.
  # The SELL side (COGS + inventory relief on deal close) is handled by DealAccountingService.
  class VehicleInventoryPostingService
    def initialize(vehicle)
      @vehicle = vehicle
      @company = vehicle.company
    end

    def post!
      return if already_posted?

      settings = AccountingSettings.for_company(@company)
      ap_account = settings.default_ap_account
      inventory_account = settings.default_vehicle_inventory_account ||
                          @company.chart_of_accounts.find_by(account_number: '1210')

      unless ap_account && inventory_account
        Rails.logger.warn("[Accounting] Skipping Vehicle #{@vehicle.id} post — missing AP (#{ap_account&.id}) or Vehicle Inventory (#{inventory_account&.id}) account")
        return nil
      end

      cost = (@vehicle.try(:total_cost) || @vehicle.try(:cost) || 0).to_d
      return nil if cost <= 0

      ActiveRecord::Base.transaction do
        je = @company.journal_entries.build(
          entry_date: @vehicle.try(:received_date) || Date.current,
          memo: "Vehicle received — #{vehicle_label}",
          source_type: 'auto',
          source_entity: @vehicle
        )

        je.journal_entry_lines.build(
          chart_of_account: inventory_account,
          debit_amount: cost,
          credit_amount: 0,
          memo: "Vehicle inventory — #{vehicle_label}",
          location_id: @vehicle.try(:location_id),
          department: department_for_vehicle,
          vehicle_id: @vehicle.id
        )

        je.journal_entry_lines.build(
          chart_of_account: ap_account,
          debit_amount: 0,
          credit_amount: cost,
          memo: "AP — Vehicle #{vehicle_label}",
          location_id: @vehicle.try(:location_id),
          department: department_for_vehicle,
          vehicle_id: @vehicle.id
        )

        unless je.save
          Rails.logger.error("[Accounting] Failed to post Vehicle #{@vehicle.id}: #{je.errors.full_messages.join(', ')}")
          raise ActiveRecord::Rollback
        end

        Rails.logger.info("[Accounting] Posted Vehicle #{@vehicle.id} → JE #{je.entry_number}")
        je
      end
    end

    private

    def already_posted?
      @company.journal_entries.where(
        source_entity_type: 'Vehicle',
        source_entity_id: @vehicle.id,
        is_void: false
      ).where("memo ILIKE 'Vehicle received%'").exists?
    end

    def vehicle_label
      "#{@vehicle.try(:stock_number) || @vehicle.id} #{@vehicle.try(:year)} #{@vehicle.try(:make)} #{@vehicle.try(:model)}".strip
    end

    def department_for_vehicle
      condition = @vehicle.try(:condition)&.to_s&.downcase
      condition&.include?('used') ? 'used_sales' : 'new_sales'
    end
  end
end
