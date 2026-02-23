class AgreementPdfService
  def initialize(agreement)
    @agreement = agreement
    @company = agreement.company
  end

  # Generate document with merge fields applied
  # Phase 1: Return document_url as-is (merge field injection comes later with HexaPDF)
  def generate_document
    # TODO: When HexaPDF is ready, inject merge_field_values into document
    @agreement.document_url
  end

  # Embed signatures onto PDF at field_placement coordinates
  # Phase 1: Placeholder — actual PDF stamping comes with HexaPDF
  def embed_signatures
    Rails.logger.info("[AgreementPdfService] Embedding signatures for agreement #{@agreement.id}")
    # TODO: Stamp signature images onto PDF at field_placement coordinates
    @agreement.document_url
  end

  # Seal the document — flatten PDF, embed audit metadata
  def seal_document
    Rails.logger.info("[AgreementPdfService] Sealing agreement #{@agreement.id}")

    # For now, copy document_url to sealed_document_url
    # When HexaPDF is ready: flatten form fields, embed audit trail, lock document
    sealed_url = @agreement.document_url

    @agreement.update!(sealed_document_url: sealed_url)

    AgreementAuditLog.log!(@agreement, AgreementAuditLog::ACTION_SEALED, metadata: {
      sealed_at: Time.current.iso8601,
      signers_count: @agreement.agreement_signers.signed.count
    })

    sealed_url
  end

  # Generate completion certificate PDF
  def generate_completion_certificate
    Rails.logger.info("[AgreementPdfService] Generating certificate for agreement #{@agreement.id}")

    # Return certificate data (frontend will render it)
    {
      agreement_number: @agreement.agreement_number,
      title: @agreement.title,
      completed_at: @agreement.completed_at,
      signers: @agreement.agreement_signers.required_signers.map do |signer|
        {
          name: signer.name,
          email: signer.email,
          role: signer.role,
          signed_at: signer.signed_at,
          signature_method: signer.signature_method,
          ip_address: signer.ip_address
        }
      end,
      audit_trail: @agreement.agreement_audit_logs.order(:created_at).map do |log|
        {
          action: log.action,
          performed_at: log.created_at,
          ip_address: log.ip_address,
          user_agent: log.user_agent
        }
      end,
      seal_hash: Digest::SHA256.hexdigest("#{@agreement.id}|#{@agreement.completed_at}|#{@agreement.agreement_signers.signed.pluck(:signature_hash).join('|')}")
    }
  end

  # Upload signature image to S3
  def self.upload_signature(file_data, agreement_id, signer_id, type = 'signature')
    # file_data is base64 encoded PNG
    return nil if file_data.blank?

    # Decode base64
    decoded = Base64.decode64(file_data.sub(/^data:image\/\w+;base64,/, ''))

    # Generate S3 key
    s3_key = "agreements/signatures/#{agreement_id}/#{signer_id}/#{type}_#{SecureRandom.uuid}.png"

    # Upload to S3
    obj = Aws::S3::Resource.new.bucket(Rails.application.credentials.dig(:aws, :bucket) || ENV['S3_BUCKET']).object(s3_key)
    obj.put(body: decoded, content_type: 'image/png', acl: 'private')

    obj.public_url
  rescue => e
    Rails.logger.error("[AgreementPdfService] Signature upload failed: #{e.message}")
    nil
  end
end
