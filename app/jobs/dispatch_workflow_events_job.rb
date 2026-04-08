class DispatchWorkflowEventsJob < ApplicationJob
  queue_as :default

  def perform
    WorkflowEvent.undispatched.where('created_at > ?', 24.hours.ago).limit(100).each do |event|
      subs = WorkflowSubscription
               .where(company_id: event.company_id, event_type: event.event_type)
               .where('entity_type_filter IS NULL OR entity_type_filter = ?', event.entity_type)

      subs.each do |sub|
        rule = sub.workflow_rule
        next unless rule && rule.status == 'active'

        entity = event.entity_type.to_s.safe_constantize&.find_by(id: event.entity_id)
        unless entity
          event.update!(dispatched_at: Time.current, dispatch_error: { reason: 'entity_not_found' })
          next
        end

        conditions_pass = WorkflowEngine::ConditionEvaluator.evaluate(
          rule.conditions,
          { 'entity' => entity.as_json, 'trigger' => event.payload }
        )
        next unless conditions_pass

        begin
          WorkflowEngine.start_run(rule: rule, entity: entity, event: event)
        rescue => e
          Rails.logger.error "[DispatchWorkflowEventsJob] failed to start run for event=#{event.id}: #{e.message}"
        end
      end

      event.update!(dispatched_at: Time.current) if event.dispatched_at.nil?
    end
  end
end
