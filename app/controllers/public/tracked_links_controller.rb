# frozen_string_literal: true

module Public
  class TrackedLinksController < ApplicationController
    skip_before_action :authenticate, raise: false
    skip_before_action :set_company_scope, raise: false
    skip_before_action :set_current_attributes, raise: false

    # GET /t/:token
    def show
      tracked_link = TrackedLink.find_by!(token: params[:token])
      tracked_link.record_click!(
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )
      redirect_to tracked_link.presigned_download_url, allow_other_host: true
    rescue ActiveRecord::RecordNotFound
      render plain: 'Link not found or expired', status: :not_found
    rescue => e
      Rails.logger.error "[TrackedLinks] redirect failed: #{e.message}"
      render plain: 'Link could not be resolved', status: :internal_server_error
    end
  end
end
