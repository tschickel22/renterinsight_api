# frozen_string_literal: true

# A reviewer flagged a surface outline (Truebuild::Trueview::Surfaces.redo!).
class TruebuildOutlineRedoJob < ApplicationJob
  queue_as :low

  def perform(mask_id, note)
    mask = TruebuildSurfaceMask.find_by(id: mask_id)
    Truebuild::Trueview::Surfaces.redo!(mask, note) if mask
  end
end
