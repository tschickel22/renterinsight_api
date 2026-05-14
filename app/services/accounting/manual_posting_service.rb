# frozen_string_literal: true

module Accounting
  class ManualPostingService
    def initialize(company)
      @company = company
    end

    def post_simple!(debit_account:, credit_account:, amount:, memo:, entry_date: Date.current,
                      source_entity: nil, location_id: nil, department: nil,
                      contact_id: nil, deal_id: nil, vehicle_id: nil, posted_by: nil)

      return if amount.nil? || amount <= 0

      je = @company.journal_entries.build(
        entry_date: entry_date,
        memo: memo,
        source_type: source_entity ? 'auto' : 'manual',
        source_entity: source_entity,
        posted_by: posted_by
      )

      je.journal_entry_lines.build(
        chart_of_account: debit_account,
        debit_amount: amount,
        credit_amount: 0,
        memo: memo,
        location_id: location_id,
        department: department,
        contact_id: contact_id,
        deal_id: deal_id,
        vehicle_id: vehicle_id
      )

      je.journal_entry_lines.build(
        chart_of_account: credit_account,
        debit_amount: 0,
        credit_amount: amount,
        memo: memo,
        location_id: location_id,
        department: department,
        contact_id: contact_id,
        deal_id: deal_id,
        vehicle_id: vehicle_id
      )

      unless je.save
        Rails.logger.error("[Accounting] ManualPostingService failed: #{je.errors.full_messages.join(', ')}")
        return nil
      end

      je
    end

    def post_complex!(lines:, memo:, entry_date: Date.current, source_entity: nil, posted_by: nil)
      je = @company.journal_entries.build(
        entry_date: entry_date,
        memo: memo,
        source_type: source_entity ? 'auto' : 'manual',
        source_entity: source_entity,
        posted_by: posted_by
      )

      lines.each do |line|
        je.journal_entry_lines.build(
          chart_of_account_id: line[:chart_of_account_id],
          debit_amount: line[:debit_amount] || 0,
          credit_amount: line[:credit_amount] || 0,
          memo: line[:memo],
          location_id: line[:location_id],
          department: line[:department],
          contact_id: line[:contact_id],
          deal_id: line[:deal_id],
          vehicle_id: line[:vehicle_id]
        )
      end

      unless je.save
        Rails.logger.error("[Accounting] ManualPostingService complex failed: #{je.errors.full_messages.join(', ')}")
        return nil
      end

      je
    end
  end
end
