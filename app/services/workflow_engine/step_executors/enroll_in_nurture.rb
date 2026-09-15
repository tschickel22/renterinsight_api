module WorkflowEngine
  module StepExecutors
    class EnrollInNurture < Base
      # Mirrors Api::Crm::Nurture::EnrollmentsController#create: one running
      # enrollment per entity, and the first step is queued. Creating the row
      # alone left it "running" with nothing ever sent.
      def call
        cfg = @step['config'] || {}
        seq = @run.company.nurture_sequences.find_by(id: cfg['nurture_sequence_id'])
        unless seq
          return { status: 'skipped', output: { reason: 'sequence_not_found' }, next_step_id: next_step_from_edges, wait: nil, error: {} }
        end

        entity = @run.entity
        existing = NurtureEnrollment.for_company(@run.company.id)
                                    .for_entity(entity.class.name, entity.id)
                                    .where(nurture_sequence_id: seq.id, status: 'running')
                                    .first
        if existing
          # A rule that fires again (lead updated, re-tagged) must not restart
          # the sequence from step one.
          return { status: 'skipped', output: { reason: 'already_enrolled', enrollment_id: existing.id }, next_step_id: next_step_from_edges, wait: nil, error: {} }
        end

        enrollment = NurtureEnrollment.transaction do
          NurtureEnrollment.for_company(@run.company.id)
                           .for_entity(entity.class.name, entity.id)
                           .where(status: 'running')
                           .update_all(status: 'paused', updated_at: Time.current)

          NurtureEnrollment.create!(
            enrollable: entity,
            nurture_sequence: seq,
            company: @run.company,
            status: 'running'
          )
        end

        ProcessNurtureStepJob.perform_later(enrollment.id)

        { status: 'success', output: { nurture_sequence_id: seq.id, enrollment_id: enrollment.id }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      rescue => e
        { status: 'skipped', output: { reason: e.message }, next_step_id: next_step_from_edges, wait: nil, error: {} }
      end
    end
  end
end
