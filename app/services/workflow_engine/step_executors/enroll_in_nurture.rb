module WorkflowEngine
  module StepExecutors
    class EnrollInNurture < Base
      def call
        cfg = @step['config'] || {}
        seq = @run.company.nurture_sequences.find_by(id: cfg['nurture_sequence_id'])
        unless seq
          return { status: 'skipped', output: { reason: 'sequence_not_found' }, next_step_id: next_step_from_edges, wait: nil, error: {} }
        end

        NurtureEnrollment.create!(
          enrollable: @run.entity,
          nurture_sequence: seq,
          company: @run.company,
          status: 'running'
        )
        { status: 'success', output: { nurture_sequence_id: seq.id }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      rescue => e
        { status: 'skipped', output: { reason: e.message }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end
    end
  end
end
