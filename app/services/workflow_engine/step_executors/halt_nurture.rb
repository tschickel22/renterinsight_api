module WorkflowEngine
  module StepExecutors
    class HaltNurture < Base
      def call
        cfg = @step['config'] || {}
        entity = @run.entity
        scope = NurtureEnrollment.for_entity(entity.class.name, entity.id).where(status: %w[idle running])
        scope = scope.where(nurture_sequence_id: cfg['nurture_sequence_id']) if cfg['nurture_sequence_id'].present?
        count = scope.update_all(status: 'paused', updated_at: Time.current)
        { status: 'success', output: { halted: count }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      rescue => e
        { status: 'skipped', output: { reason: e.message }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end
    end
  end
end
