# frozen_string_literal: true

# A reviewer flagged a surface outline (Truebuild::Trueview::Surfaces.redo!).
class TruebuildOutlineRedoJob < ApplicationJob
  queue_as :low

  # run_id: the factory run waiting on it, which may now be done (a redo
  # that found nothing to cut again queues no drawing to say so).
  def perform(mask_id, note, run_id = nil)
    mask = TruebuildSurfaceMask.find_by(id: mask_id)
    Truebuild::Trueview::Surfaces.redo!(mask, note) if mask
  ensure
    run = run_id && TruebuildFactoryRun.find_by(id: run_id)
    Truebuild::Trueview::FactoryRun.drawing_finished!(run) if run
  end
end
