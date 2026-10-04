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
    # A stopped or budget-reached batch run still has its batches at Google
    # collected: those drawings are paid for. Only a running one sends more.
    TruebuildFactoryRun.where(status: %w[running stopped budget_reached], mode: 'batch').find_each do |run|
      batch = Truebuild::Trueview::Batch
      next unless run.status == 'running' || run.renders.where(status: 'running').where("usage ? 'batch_name'").exists?

      batch.poll!(run)
      next unless run.reload.status == 'running'

      batch.submit!(run)
      Truebuild::Trueview::FactoryRun.drawing_finished!(run.reload)
    rescue StandardError => e
      Rails.logger.warn("TruebuildFactoryRunTickJob run #{run.id}: #{e.message}")
    end
  end
end
