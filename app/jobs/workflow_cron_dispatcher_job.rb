# Dispatches cron-triggered workflow rules.
#
# Dedup approach: before firing, we check whether a matching WorkflowEvent was
# created in the last 5 minutes for the same company + event_type. If so we
# skip (prevents double-fire within the minute when solid_queue retries or the
# minute-window condition is briefly true twice).
class WorkflowCronDispatcherJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current
    Company.find_each do |company|
      rules = WorkflowRule.where(company: company, status: 'active')
      rules.find_each do |rule|
        trig = rule.trigger || {}
        event_type = trig['event_type'].to_s
        next unless event_type.start_with?('cron.')
        next unless due?(event_type, trig, now)

        # Dedup: skip if an event of this type was already created for this
        # company in the last 5 minutes.
        already = WorkflowEvent.where(company: company, event_type: event_type)
                               .where(created_at: 5.minutes.ago..)
                               .exists?
        next if already

        entities = WorkflowEngine::CronQueries.run(trig['query'], company)
        Array(entities).each do |entity|
          WorkflowEvent.create!(
            company: company,
            event_type: event_type,
            entity_type: entity.class.name,
            entity_id: entity.id,
            payload: { 'cron' => true, 'query' => trig['query'] }
          )
        end

        # Always record a marker event so dedup works even when no entities
        # match — use entity_type/id 'Cron'/0 sentinel.
        if Array(entities).empty?
          WorkflowEvent.create!(
            company: company,
            event_type: event_type,
            entity_type: 'Cron',
            entity_id: 0,
            payload: { 'cron' => true, 'query' => trig['query'], 'empty' => true }
          )
        end
      end
    end

    DispatchWorkflowEventsJob.perform_later
  rescue => e
    Rails.logger.error "[WorkflowCronDispatcherJob] #{e.class}: #{e.message}"
  end

  private

  def due?(event_type, trig, now)
    case event_type
    when 'cron.minutely'
      true
    when 'cron.hourly'
      now.min == 0
    when 'cron.daily'
      hour = (trig['at_hour'] || 9).to_i
      now.hour == hour && now.min < 5
    when 'cron.weekly'
      wday = (trig['on_wday'] || 1).to_i
      hour = (trig['at_hour'] || 9).to_i
      now.wday == wday && now.hour == hour && now.min < 5
    else
      false
    end
  end
end
