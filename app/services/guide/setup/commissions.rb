# frozen_string_literal: true

module Guide
  module Setup
    # A dealership's commission plans in plain words, for the help assistant
    # (E118). Commissions were the most asked area in the month before this
    # was built (13 of 73 customer questions).
    #
    # Guide::SetupAreas has already checked the module is on the plan and the
    # person can read commission plans (Tom, 2026-11-24: no plan read, no
    # answer, not even their own plan). Plans are narrowed to the person's
    # locations exactly as the connector narrows them.
    class Commissions
      MAX_PLANS = 8

      def initialize(ctx)
        @ctx = ctx
        @company = ctx.company
      end

      def to_h
        plans = @ctx.scope_locations(@company.commission_plans, include_unlocated: true)
                    .includes(:commission_components).order(:name).to_a
        live = plans.select { |p| %w[current future].include?(McpTools::CommissionPlanSupport.status(p)) }
        shown = live.first(MAX_PLANS)

        {
          how_a_deal_gets_its_plan: 'A deal uses the plan chosen on the deal if one was picked. Otherwise the active, ' \
                                    'current plan assigned to its salesperson, then one assigned to their role, then ' \
                                    'the company default.',
          your_plan: fact { your_plan },
          commission_becomes_payable: fact { CommissionSettings.payable_at(@company) },
          plans: shown.map { |p| plan(p) },
          more_plans: live.size > shown.size ? live.size - shown.size : nil,
          inactive_or_expired_plans: plans.size - live.size
        }.compact
      end

      private

      # A savepoint, so one failed query never spoils the ones after it.

      def fact(&block)

        ActiveRecord::Base.transaction(requires_new: true, &block)
      rescue StandardError => e
        Rails.logger.info("[Guide::Setup::Commissions] skipped a fact: #{e.class} #{e.message}")
        nil
      end

      def your_plan
        found = CommissionPlan.for_salesperson(@ctx.user, @company)
        found ? found.name : 'none applies to you (no plan for you, your role, or a company default)'
      end

      def plan(p)
        base = McpTools::CommissionPlanSupport.plan_json(@ctx, p, detailed: false)
        base[:components] = Array(base[:components]).map { |c| c.slice(:name, :applies_to_role, :gross_type, :pays, :deal_type, :vertical) }
        guide = fact { CommissionPlanGuide.new(p).as_json }
        base.merge(
          in_plain_words: guide && guide[:summary].presence,
          watch_out_for: guide && guide[:warnings].presence,
          setup_steps_left: guide && Array(guide[:checklist]).reject { |s| s[:done] || s[:optional] }.map { |s| s[:label] }.presence
        ).compact
      end
    end
  end
end
