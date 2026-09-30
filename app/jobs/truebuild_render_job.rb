# frozen_string_literal: true

# Draws one TrueView rendering (Truebuild::Trueview.perform!).
class TruebuildRenderJob < ApplicationJob
  queue_as :default

  def perform(render_id)
    render = TruebuildRender.find_by(id: render_id)
    Truebuild::Trueview.perform!(render) if render && render.status == 'queued'
  end
end
