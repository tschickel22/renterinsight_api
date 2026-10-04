# frozen_string_literal: true

module Public
  # GET /pf/:token — opens a file behind a PrivateFiles.durable_url. The token
  # is signed, so it can only name a file we issued a link for; each open gets
  # a presigned URL that lives five minutes.
  class PrivateFilesController < ApplicationController
    skip_before_action :authenticate, raise: false
    skip_before_action :set_company_scope, raise: false
    skip_before_action :set_current_attributes, raise: false

    def show
      ref = PrivateFiles.from_durable_token(params[:token])
      url = ref && PrivateFiles.url(ref, expires_in: 5.minutes)
      return head :not_found if url.blank? || !PrivateFiles.located?(ref)

      redirect_to url, allow_other_host: true, status: :found
    end
  end
end
