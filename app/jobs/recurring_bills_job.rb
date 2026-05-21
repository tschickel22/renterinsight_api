# frozen_string_literal: true

class RecurringBillsJob < ApplicationJob
  queue_as :default

  def perform
    RecurringBill.active.due.find_each do |bill|
      next unless bill.auto_post

      je = bill.generate_entry!
      unless je
        err = bill.last_error || { message: 'unknown error' }
        Rails.logger.error("[RecurringBills] Failed to generate for #{bill.id}: #{err[:message]}")
      end
    rescue => e
      Rails.logger.error("[RecurringBills] Error processing bill #{bill.id}: #{e.message}")
    end
  end
end
