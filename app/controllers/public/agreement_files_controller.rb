# frozen_string_literal: true

module Public
  # GET /agreement_files/:token
  # The link Share sends. A valid, unexpired token opens the signed PDF through
  # a short-lived S3 link; anything else gets a plain "no longer available".
  # A sensitive agreement's link opens its password-locked copy, and only while
  # the agreement's share window is open.
  class AgreementFilesController < ApplicationController
    skip_before_action :authenticate

    def show
      agreement, file = Agreements::Share.resolve(params[:token])
      unless agreement && file && !agreement.is_deleted && Agreements::Share.shareable?(agreement)
        return render plain: 'This link has expired or is no longer available. Ask the dealer to send it again.',
                      status: :not_found
      end

      AgreementAuditLog.log!(agreement, AgreementAuditLog::ACTION_DOWNLOADED,
                             ip_address: request.remote_ip, user_agent: request.user_agent,
                             metadata: { 'via' => 'share_link', 'locked' => agreement.sensitive? })
      name = agreement.sensitive? ? agreement.title.to_s.tr('/\\', '-') : agreement.agreement_number
      redirect_to PrivateFiles.url(file, expires_in: 10.minutes, filename: "#{name}.pdf"), allow_other_host: true
    end
  end
end
