# frozen_string_literal: true

class ProcessExportJob < ApplicationJob
  queue_as :default

  def perform(export_job_id)
    job = ExportJob.find(export_job_id)
    ImportExport::Exporter.new(job).process!
  rescue StandardError => e
    Rails.logger.error "[ProcessExportJob] #{e.class}: #{e.message}"
  end
end
