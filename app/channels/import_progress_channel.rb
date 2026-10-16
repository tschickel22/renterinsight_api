# frozen_string_literal: true

# Progress of an import, for people in the company that ran it.
class ImportProgressChannel < ApplicationCable::Channel
  def subscribed
    job = ImportJob.find_by(id: params[:import_job_id], company_id: current_user.company_id)
    job ? stream_from("import_progress_#{job.id}") : reject
  end
end
