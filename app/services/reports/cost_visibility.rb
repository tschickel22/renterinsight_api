# frozen_string_literal: true

module Reports
  # Strips cost and margin from a report for someone who may see the report but
  # not what the dealership paid.
  #
  # Visibility and sensitivity are separate questions. Whether Deal
  # Profitability opens is `sales_reports`; whether its margin columns render is
  # `deals:read:view_cost_details`. Keeping them apart is what lets a sales rep
  # see which deals closed and at what price without seeing landed cost, and it
  # means a mis-set report permission cannot leak margin on its own.
  #
  # Removes the keys rather than nulling them: a nil reads as "zero margin" in
  # most UIs, which is a worse lie than an absent column.
  module CostVisibility
    # Anything that reveals what the unit cost or what was made on it.
    COST_KEYS = %i[
      landed_cost cost_entered cost_flag
      front_gross commissionable_front_gross back_gross total_gross
      net_profit carrying_costs front_detail
    ].freeze

    SUMMARY_COST_KEYS = %i[
      total_front_gross total_back_gross total_gross_profit
      total_net_profit gross_margin
    ].freeze

    # @param report [Hash] as built by DealProfitabilityReportService
    # @param can_view_costs [Boolean] deals:read:view_cost_details
    # @return [Hash] the report, with cost removed when it may not be seen
    def self.apply(report, can_view_costs:)
      return report if can_view_costs
      return report unless report.is_a?(Hash)

      scrubbed = report.dup
      scrubbed[:deals] = Array(report[:deals]).map { |row| row.except(*COST_KEYS) } if report.key?(:deals)
      scrubbed[:summary] = report[:summary].except(*SUMMARY_COST_KEYS) if report[:summary].is_a?(Hash)
      # So a client can say "costs hidden" rather than quietly showing less.
      scrubbed[:can_view_costs] = false
      scrubbed
    end
  end
end
