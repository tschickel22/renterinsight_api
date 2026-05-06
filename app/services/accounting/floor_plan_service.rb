# frozen_string_literal: true

module Accounting
  class FloorPlanService
    def initialize(company)
      @company = company
    end

    def daily_interest_accrual
      accrued_count = 0
      total_interest = BigDecimal('0')

      floor_planned_vehicles.find_each do |vehicle|
        daily_rate = (vehicle.floor_plan_rate || 0) / 365.0
        daily_interest = (vehicle.floor_plan_amount || 0) * daily_rate

        next if daily_interest.zero?

        posting_service = ManualPostingService.new(@company)

        fp_interest_expense = @company.chart_of_accounts.find_by(account_number: '5300')
        fp_interest_payable = @company.chart_of_accounts.find_by(account_number: '2130')

        next unless fp_interest_expense && fp_interest_payable

        je = posting_service.post_simple!(
          debit_account: fp_interest_expense,
          credit_account: fp_interest_payable,
          amount: daily_interest.round(2),
          memo: "Floor plan interest — #{vehicle.stock_number} #{vehicle.year} #{vehicle.make} #{vehicle.model}",
          entry_date: Date.current,
          source_entity: vehicle,
          vehicle_id: vehicle.id,
          location_id: vehicle.try(:location_id),
          department: 'new_sales'
        )

        if je
          vehicle.increment!(:floor_plan_accrued_interest, daily_interest.round(2))
          days = vehicle.floor_plan_start_date ? (Date.current - vehicle.floor_plan_start_date).to_i : 0
          vehicle.update_column(:days_on_floor_plan, days)
          accrued_count += 1
          total_interest += daily_interest
        end
      end

      Rails.logger.info("[FloorPlan] Daily accrual complete: #{accrued_count} vehicles, $#{total_interest.round(2)} total interest")
      { vehicles_processed: accrued_count, total_interest: total_interest.round(2) }
    end

    def curtail!(vehicle, user: nil)
      return { error: 'No floor plan amount' } unless vehicle.floor_plan_amount&.positive?

      posting_service = ManualPostingService.new(@company)

      fp_liability = @company.chart_of_accounts.find_by(account_number: '2110')
      bank_account = @company.chart_of_accounts.where(sub_type: 'bank', is_active: true).order(:account_number).first

      return { error: 'Missing GL accounts' } unless fp_liability && bank_account

      je = posting_service.post_simple!(
        debit_account: fp_liability,
        credit_account: bank_account,
        amount: vehicle.floor_plan_amount,
        memo: "Floor plan curtailment — #{vehicle.stock_number} #{vehicle.year} #{vehicle.make} #{vehicle.model}",
        entry_date: Date.current,
        source_entity: vehicle,
        vehicle_id: vehicle.id,
        location_id: vehicle.try(:location_id),
        posted_by: user
      )

      if je
        vehicle.update!(
          floor_plan_curtailed_at: Date.current,
          floor_plan_amount: 0
        )
        { success: true, journal_entry: je }
      else
        { error: 'Failed to post curtailment entry' }
      end
    end

    def report(location_id: nil)
      vehicles = floor_planned_vehicles
      vehicles = vehicles.where(location_id: location_id) if location_id

      rows = vehicles.map do |v|
        days = v.floor_plan_start_date ? (Date.current - v.floor_plan_start_date).to_i : 0
        daily_rate = (v.floor_plan_rate || 0) / 365.0
        monthly_interest = (v.floor_plan_amount || 0) * daily_rate * 30

        {
          vehicle_id: v.id,
          stock_number: v.stock_number,
          year: v.year,
          make: v.make,
          model: v.model,
          vin: v.try(:vin),
          location_id: v.try(:location_id),
          floor_plan_amount: v.floor_plan_amount,
          floor_plan_rate: v.floor_plan_rate,
          floor_plan_lender: v.floor_plan_lender,
          start_date: v.floor_plan_start_date,
          days_on_plan: days,
          accrued_interest: v.floor_plan_accrued_interest || 0,
          monthly_interest_estimate: monthly_interest.round(2),
          status: v.try(:status)
        }
      end

      total_principal = rows.sum { |r| r[:floor_plan_amount] || 0 }
      total_accrued = rows.sum { |r| r[:accrued_interest] }

      {
        vehicles: rows,
        summary: {
          total_vehicles: rows.count,
          total_principal: total_principal,
          total_accrued_interest: total_accrued,
          avg_days_on_plan: rows.any? ? (rows.sum { |r| r[:days_on_plan] } / rows.count.to_f).round(1) : 0
        }
      }
    end

    private

    def floor_planned_vehicles
      scope = @company.vehicles.where('floor_plan_amount > 0')
      scope = scope.where(floor_plan_curtailed_at: nil) if Vehicle.column_names.include?('floor_plan_curtailed_at')
      if Vehicle.column_names.include?('status')
        scope = scope.where.not(status: ['sold', 'delivered'])
      end
      scope
    end
  end
end
