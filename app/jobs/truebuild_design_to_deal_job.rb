# frozen_string_literal: true

# A saved design reaches the buyer's open deal (Truebuild::DesignToDeal).
class TruebuildDesignToDealJob < ApplicationJob
  queue_as :default

  def perform(design_id)
    design = TruebuildDesign.find_by(id: design_id)
    Truebuild::DesignToDeal.call(design) if design
  end
end
