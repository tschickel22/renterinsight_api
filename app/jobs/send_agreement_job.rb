class SendAgreementJob < ApplicationJob
  queue_as :default

  def perform(agreement_id)
    agreement = Agreement.find_by(id: agreement_id)
    return unless agreement
    return unless agreement.status == Agreement::STATUS_SENT

    agreement.agreement_signers.each do |signer|
      next if signer.is_cc? && false # CCs get notified differently

      begin
        # Send signing invitation email
        # Use your existing email service/mailer
        Rails.logger.info("[SendAgreementJob] Sending agreement #{agreement.agreement_number} to #{signer.email} (#{signer.role})")

        # TODO: Wire up to actual mailer
        # AgreementMailer.signing_invitation(agreement, signer).deliver_now

        if signer.phone.present?
          Rails.logger.info("[SendAgreementJob] Sending SMS to #{signer.phone}")
          # TODO: Wire up to Twilio SMS
        end
      rescue => e
        Rails.logger.error("[SendAgreementJob] Failed to send to #{signer.email}: #{e.message}")
      end
    end
  end
end
