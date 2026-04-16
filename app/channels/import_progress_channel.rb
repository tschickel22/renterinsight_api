# frozen_string_literal: true

class ImportProgressChannel < ApplicationCable::Channel
  def subscribed
    stream_from "import_progress_#{params[:import_job_id]}"
  end
end
