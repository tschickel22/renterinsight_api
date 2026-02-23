class SealAgreementJob < ApplicationJob
  queue_as :default

  def perform(agreement_id)
    agreement = Agreement.find_by(id: agreement_id)
    return unless agreement
    return unless agreement.status == Agreement::STATUS_COMPLETED

    pdf_service = AgreementPdfService.new(agreement)

    # Embed signatures into document
    pdf_service.embed_signatures

    # Seal the document
    pdf_service.seal_document

    Rails.logger.info("[SealAgreementJob] Agreement #{agreement.agreement_number} sealed successfully")
  rescue => e
    Rails.logger.error("[SealAgreementJob] Failed to seal agreement #{agreement_id}: #{e.message}")
  end
end
