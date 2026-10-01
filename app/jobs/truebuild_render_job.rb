# frozen_string_literal: true

# Draws one TrueView rendering (Truebuild::Trueview.perform!).
#
# A deploy can stop a worker mid-drawing; solid_queue then runs the same job
# again. The row is already 'running' by then, so the job records which job
# claimed it and carries on when it is that same job, rather than skipping
# and leaving the row 'running' for good.
class TruebuildRenderJob < ApplicationJob
  queue_as :default

  def perform(render_id)
    render = TruebuildRender.find_by(id: render_id)
    return unless render
    return unless render.status == 'queued' || (render.status == 'running' && render.usage['job_id'] == job_id)

    render.update_columns(usage: render.usage.merge('job_id' => job_id))
    Truebuild::Trueview.perform!(render)
  end
end
