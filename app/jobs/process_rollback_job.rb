# frozen_string_literal: true

class ProcessRollbackJob < ApplicationJob
  queue_as :default

  def perform(import_job_id)
    job = ImportJob.find(import_job_id)
    ImportExport::RollbackService.new(job).rollback!
  rescue StandardError => e
    Rails.logger.error "[ProcessRollbackJob] #{e.class}: #{e.message}"
  end
end
