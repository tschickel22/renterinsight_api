# frozen_string_literal: true

module McpTools
  # Commission plans through the connector (see Areas). Design only: plans
  # are read, tested on example deals and saved as inactive drafts. What a
  # person earned never comes through here, and nothing here activates a plan.
  #
  # Undo:
  #   plan the AI created   deleted with its components while still inactive,
  #                         unused and exactly as the AI left it
  #   edits to a draft      restored while still inactive, unused and as left
  module CommissionArea
    READ_TOOLS = [McpTools::ListCommissionPlans, McpTools::GetCommissionPlan, McpTools::SimulateCommissionPlan].freeze
    WRITE_TOOLS = [McpTools::CreateCommissionPlanDraft, McpTools::UpdateCommissionPlanDraft].freeze
    PROMPTS = [McpPrompts::ExplainCommissionPlan, McpPrompts::CompareCommissionPlans].freeze

    module_function

    def handles?(record)
      record.is_a?(CommissionPlan)
    end

    def label(record_type)
      'draft commission plan' if record_type == 'CommissionPlan'
    end

    def undo_created(change, plan)
      return blocked(plan) if blocked(plan)
      unless Undo.same_value?(CommissionPlanSupport.snapshot(plan), change.after)
        return Undo.skipped('The plan was edited since. Remove it in DealerTide if it should go.')
      end

      CommissionPlan.transaction do
        plan.commission_components.each(&:destroy!)
        plan.destroy!
      end
      Undo.done('Draft commission plan deleted.')
    end

    def undo_updated(change, plan)
      return blocked(plan) if blocked(plan)
      unless Undo.same_value?(CommissionPlanSupport.snapshot(plan), change.after)
        return Undo.skipped('The plan was changed again since. Left as it is.')
      end

      before = change.before
      CommissionPlan.transaction do
        plan.update!(before.slice(*CommissionPlanSupport::PLAN_FIELDS))
        plan.commission_components.each(&:destroy!)
        Array(before['components']).each do |attrs|
          plan.company.commission_components.create!(attrs.merge('commission_plan_id' => plan.id,
                                                                 'location_id' => plan.location_id))
        end
      end
      Undo.done('Draft commission plan restored to how it was before the edit.')
    end

    def blocked(plan)
      if plan.is_active
        Undo.skipped('The plan has been activated since. Deactivate it in DealerTide if it should stop.')
      elsif CommissionPlanSupport.in_use?(plan)
        Undo.skipped('Deals use the plan now. Change it in DealerTide.')
      end
    end
  end
end
