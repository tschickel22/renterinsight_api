# frozen_string_literal: true

module Reports
  class DepartmentalPnlReportService
    DEPARTMENTS = %w[new_sales used_sales service parts fi admin].freeze
    DEPARTMENT_LABELS = {
      'new_sales'  => 'New Home Sales',
      'used_sales' => 'Used Home Sales',
      'service'    => 'Service',
      'parts'      => 'Parts',
      'fi'         => 'F&I',
      'admin'      => 'Administration'
    }.freeze

    def initialize(company)
      @company = company
    end

    def generate(start_date:, end_date:, location_id: nil)
      pnl_service = ProfitAndLossReportService.new(@company)

      company_pnl = pnl_service.generate(
        start_date: start_date, end_date: end_date, location_id: location_id
      )

      departments = DEPARTMENTS.map do |dept|
        dept_pnl = pnl_service.generate(
          start_date: start_date, end_date: end_date, location_id: location_id, department: dept
        )

        {
          department: dept,
          label: DEPARTMENT_LABELS[dept],
          revenue: dept_pnl[:total_revenue],
          cogs: dept_pnl[:total_cogs],
          gross_profit: dept_pnl[:gross_profit],
          expenses: dept_pnl[:total_expenses],
          net_income: dept_pnl[:net_income],
          gross_margin: dept_pnl[:gross_margin],
          detail: dept_pnl
        }
      end

      {
        period: { start_date: start_date, end_date: end_date },
        location_id: location_id,
        company_total: company_pnl,
        departments: departments.select { |d| d[:revenue] > 0 || d[:expenses] > 0 }
      }
    end
  end
end
