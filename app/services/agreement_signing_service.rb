class AgreementSigningService
  def self.validate_token(token)
    signer = AgreementSigner.find_by(access_token: token)
    return { valid: false, error: 'Invalid or expired link' } unless signer

    agreement = signer.agreement

    if agreement.status == Agreement::STATUS_VOIDED
      return { valid: false, error: 'This agreement has been voided' }
    end

    if agreement.status == Agreement::STATUS_EXPIRED || agreement.expired?
      return { valid: false, error: 'This agreement has expired' }
    end

    if agreement.status == Agreement::STATUS_COMPLETED
      return { valid: false, error: 'This agreement has already been completed', completed: true, signer: signer }
    end

    if signer.status == AgreementSigner::STATUS_SIGNED
      return { valid: false, error: 'You have already signed this agreement', already_signed: true, signer: signer }
    end

    if signer.status == AgreementSigner::STATUS_DECLINED
      return { valid: false, error: 'You have already declined this agreement', signer: signer }
    end

    { valid: true, signer: signer, agreement: agreement }
  end

  def self.process_signature(signer, params)
    agreement = signer.agreement

    # Upload signature image to S3 if base64 provided
    signature_url = params[:signature_url]
    if params[:signature_data].present? && signature_url.blank?
      signature_url = AgreementPdfService.upload_signature(
        params[:signature_data], agreement.id, signer.id, 'signature'
      )
    end

    # Upload initials image to S3 if base64 provided
    initials_url = params[:initials_url]
    if params[:initials_data].present? && initials_url.blank?
      initials_url = AgreementPdfService.upload_signature(
        params[:initials_data], agreement.id, signer.id, 'initials'
      )
    end

    signer.sign!(
      signature_url: signature_url,
      signature_method: params[:signature_method],
      initials_url: initials_url,
      initials_method: params[:initials_method],
      typed_signature: params[:typed_signature],
      typed_initials: params[:typed_initials],
      signature_font: params[:signature_font],
      ip_address: params[:ip_address],
      user_agent: params[:user_agent]
    )
  end
end
