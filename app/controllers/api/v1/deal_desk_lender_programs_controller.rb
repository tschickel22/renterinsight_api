# frozen_string_literal: true

module Api
  module V1
    # Read-only list of lender programs (with their tier matrix) to populate the Deal Desk
    # lender/program dropdown. @company-scoped, gated by deal_desk:read.
    class DealDeskLenderProgramsController < ApplicationController
      include ModuleAccessRequired

      before_action :set_company_scope
      require_module! 'sales.deal_desk'

      # GET /api/v1/deal_desk/lender_programs
      def index
        return unless authorize_action!('deal_desk', 'read')

        programs = @company.lender_programs.active.ordered.includes(:tiers)
        render json: { lender_programs: programs.map { |p| program_json(p) } }
      end

      private

      def program_json(program)
        {
          id: program.id,
          lender_name: program.lender_name,
          program_name: program.program_name,
          collateral_type: program.collateral_type,
          is_seeded: program.is_seeded,
          tiers: program.tiers.map do |t|
            {
              id: t.id, tier_label: t.tier_label,
              fico_min: t.fico_min, fico_max: t.fico_max,
              collateral_age_min_years: t.collateral_age_min_years,
              collateral_age_max_years: t.collateral_age_max_years,
              loan_amount_min: t.loan_amount_min, loan_amount_max: t.loan_amount_max,
              rate: t.rate, max_term_months: t.max_term_months, max_ltv: t.max_ltv
            }
          end
        }
      end
    end
  end
end
