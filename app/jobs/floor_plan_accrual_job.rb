# frozen_string_literal: true

class FloorPlanAccrualJob < ApplicationJob
  queue_as :default

  def perform
    Company.find_each do |company|
      next unless company.accounting_settings.present?
      next unless company.chart_of_accounts.exists?

      service = Accounting::FloorPlanService.new(company)
      result = service.daily_interest_accrual
      Rails.logger.info("[FloorPlanAccrualJob] Company #{company.id}: #{result}")
    rescue => e
      Rails.logger.error("[FloorPlanAccrualJob] Company #{company.id} failed: #{e.message}")
    end
  end
end
