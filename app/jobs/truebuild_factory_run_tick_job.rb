# frozen_string_literal: true

# Every few minutes (config/recurring.yml): starts scheduled factory runs
# whose time has come, sends a batch run's waiting drawings to Google and
# collects the batches Google has finished. A run scheduled for tonight and
# drawn by batch needs nobody to watch it.
class TruebuildFactoryRunTickJob < ApplicationJob
  queue_as :low
  limits_concurrency to: 1, key: 'truebuild-factory-run-tick', duration: 30.minutes

  def perform
    TruebuildFactoryRun.due.find_each { |run| Truebuild::Trueview::FactoryRun.begin!(run) }
    TruebuildFactoryRun.where(status: 'running', mode: 'batch').find_each do |run|
      batch = Truebuild::Trueview::Batch
      batch.poll!(run)
      batch.submit!(run) if run.reload.status == 'running'
      Truebuild::Trueview::FactoryRun.drawing_finished!(run.reload)
    rescue StandardError => e
      Rails.logger.warn("TruebuildFactoryRunTickJob run #{run.id}: #{e.message}")
    end
  end
end
