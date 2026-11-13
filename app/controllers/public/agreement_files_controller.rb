# frozen_string_literal: true

module Public
  # GET /agreement_files/:token
  # The link Share sends. A valid, unexpired token opens the signed PDF through
  # a short-lived S3 link; anything else gets a plain "no longer available".
  class AgreementFilesController < ApplicationController
    skip_before_action :authenticate

    def show
      agreement = Agreements::Share.find_by_token(params[:token])
      unless agreement && !agreement.is_deleted && Agreements::Share.shareable?(agreement)
        return render plain: 'This link has expired or is no longer available. Ask the dealer to send it again.',
                      status: :not_found
      end

      AgreementAuditLog.log!(agreement, AgreementAuditLog::ACTION_DOWNLOADED,
                             ip_address: request.remote_ip, user_agent: request.user_agent,
                             metadata: { 'via' => 'share_link' })
      redirect_to PrivateFiles.url(agreement.sealed_document_url, expires_in: 10.minutes,
                                                                  filename: "#{agreement.agreement_number}.pdf"),
                  allow_other_host: true
    end
  end
end
