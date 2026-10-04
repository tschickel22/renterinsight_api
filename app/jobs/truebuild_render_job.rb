class TruebuildRenderJob < ApplicationJob
  queue_as :default

  # A row younger than this may not have its job enqueued yet.
  GRACE = 2.minutes

  def perform(render_id)
    render = TruebuildRender.find_by(id: render_id)
    return unless render
    # A job the queue re-runs after its worker died finds its own row still
    # "running"; it carries on. Any other job for a running row is a duplicate.
    return unless render.status == 'queued' || (render.status == 'running' && render.usage['job_id'] == job_id)

    render.update_columns(usage: render.usage.merge('job_id' => job_id))
    Truebuild::Trueview.perform!(render)
    run_finished(render)
  end

  # The last drawing of a factory run starts its repair round.
  def run_finished(render)
    run = TruebuildFactoryRun.find_by(id: render.reload.usage['factory_run_id']) or return
    Truebuild::Trueview::FactoryRun.drawing_finished!(run)
  rescue StandardError => e
    Rails.logger.warn("TruebuildRenderJob run_finished #{render.id}: #{e.message}")
  end

  # Queued or running rows that no job will ever finish (a deploy restarted
  # the worker, or the enqueue was lost). Under Solid Queue that is any row
  # without an unfinished job; elsewhere it falls back to age.
  def self.orphaned(scope, stale_after:)
    # A batch run's drawings have no job: Batch submits and collects them.
    rows = scope.where(status: %w[queued running]).where(updated_at: ...GRACE.ago).where("usage->>'batch' IS NULL").to_a
    live = live_render_ids
    return rows.select { |r| r.updated_at < stale_after.ago } if live.nil?

    # A drawing under way is never taken for lost on the queue's word alone:
    # requeuing it starts a second, paid drawing of the same layer.
    rows.reject { |r| live.include?(r.id) || (r.status == 'running' && r.updated_at > stale_after.ago) }
  end

  def self.requeue(row, queue: :default)
    row.update!(status: 'queued', usage: row.usage.except('job_id'))
    set(queue: queue).perform_later(row.id)
  end

  def self.live_render_ids
    return nil unless ActiveJob::Base.queue_adapter.is_a?(ActiveJob::QueueAdapters::SolidQueueAdapter)

    # The queue hands arguments back already decoded (serialize coder: JSON).
    # Parsed again they always failed, so no drawing had a live job and every
    # one waiting over two minutes was queued again, on every page refresh.
    SolidQueue::Job.where(class_name: name, finished_at: nil).pluck(:arguments).filter_map do |args|
      args = JSON.parse(args) if args.is_a?(String)
      args.is_a?(Hash) ? Array(args['arguments']).first.to_i : nil
    rescue JSON::ParserError
      nil
    end.to_set
  rescue StandardError => e
    Rails.logger.warn("TruebuildRenderJob.live_render_ids: #{e.message}")
    nil
  end
end
