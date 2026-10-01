# frozen_string_literal: true

# Queues a factory run's drawings model by model (Truebuild::Trueview::FactoryRun).
# Picks up where it left off if a deploy restarts it.
class TruebuildFactoryRunJob < ApplicationJob
  queue_as :low

  def perform(run_id)
    run = TruebuildFactoryRun.find_by(id: run_id)
    Truebuild::Trueview::FactoryRun.queue!(run) if run&.status == 'running'
  end
end
