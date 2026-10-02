# frozen_string_literal: true

# One repair round of a factory run (Truebuild::Trueview::FactoryRun.repair!).
class TruebuildFactoryRunRepairJob < ApplicationJob
  queue_as :low

  def perform(run_id)
    run = TruebuildFactoryRun.find_by(id: run_id)
    Truebuild::Trueview::FactoryRun.repair!(run) if run&.status == 'running'
  end
end
