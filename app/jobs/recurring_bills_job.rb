# frozen_string_literal: true

class RecurringBillsJob < ApplicationJob
  queue_as :default

  def perform
    RecurringBill.active.due.find_each do |bill|
      next unless bill.auto_post

      result = bill.generate_entry!
      if result.is_a?(Hash) && result[:error]
        Rails.logger.error("[RecurringBills] Failed to generate for #{bill.id}: #{result[:error]}")
      end
    rescue => e
      Rails.logger.error("[RecurringBills] Error processing bill #{bill.id}: #{e.message}")
    end
  end
end
