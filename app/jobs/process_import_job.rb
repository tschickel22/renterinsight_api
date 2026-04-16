# frozen_string_literal: true

class ProcessImportJob < ApplicationJob
  queue_as :default

  def perform(import_job_id)
    job = ImportJob.find(import_job_id)
    ImportExport::Importer.new(job).process!
  rescue StandardError => e
    Rails.logger.error "[ProcessImportJob] #{e.class}: #{e.message}"
  end
end
