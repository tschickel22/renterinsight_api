class DispatchWorkflowEventsJob < ApplicationJob
  queue_as :default

  def perform
    WorkflowEvent.undispatched.where('created_at > ?', 24.hours.ago).limit(100).each do |event|
      # Claim the event before acting on it. Every emit enqueues this job, so a
      # save that emits two events (lead.updated and lead.status_changed) runs
      # two copies at once, and both used to read the same undispatched event
      # and start its rules twice: duplicate follow-up calls, and in
      # production duplicate "Day 0 - New Lead First Touch" runs. Only one job
      # can flip dispatched_at, so only one starts the rules.
      claimed = WorkflowEvent.where(id: event.id, dispatched_at: nil).update_all(dispatched_at: Time.current)
      next if claimed.zero?

      subs = WorkflowSubscription
               .where(company_id: event.company_id, event_type: event.event_type)
               .where('entity_type_filter IS NULL OR entity_type_filter = ?', event.entity_type)

      subs.each do |sub|
        rule = sub.workflow_rule
        next unless rule && rule.status == 'active'

        entity = event.entity_type.to_s.safe_constantize&.find_by(id: event.entity_id)
        unless entity
          event.update_columns(dispatch_error: { reason: 'entity_not_found' })
          next
        end

        conditions_pass = WorkflowEngine::ConditionEvaluator.evaluate(
          rule.conditions,
          entity,
          trigger: event.payload || {}
        )
        next unless conditions_pass

        begin
          WorkflowEngine.start_run(rule: rule, entity: entity, event: event)
        rescue => e
          Rails.logger.error "[DispatchWorkflowEventsJob] failed to start run for event=#{event.id}: #{e.message}"
        end
      end
    end
  end
end
