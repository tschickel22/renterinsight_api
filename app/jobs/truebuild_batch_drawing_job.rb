# frozen_string_literal: true

# Cuts and checks one drawing a Gemini batch returned (Truebuild::Trueview::Batch.check!).
class TruebuildBatchDrawingJob < ApplicationJob
  queue_as :low

  def perform(render_id)
    render = TruebuildRender.find_by(id: render_id)
    return unless render&.status == 'running' && render.usage['batch_drawn']

    Truebuild::Trueview::Batch.check!(render)
  rescue StandardError => e
    render&.update!(status: 'failed', error: e.message.to_s.first(1000))
  ensure
    run = render && TruebuildFactoryRun.find_by(id: render.reload.usage['factory_run_id'])
    Truebuild::Trueview::FactoryRun.drawing_finished!(run) if run
  end
end
