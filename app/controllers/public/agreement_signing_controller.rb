module Public
  class AgreementSigningController < ApplicationController
    skip_before_action :authenticate
    before_action :find_signer
    before_action :validate_agreement_status, except: [:download]

    # GET /sign/:token
    def show
      company = @agreement.company

      render json: {
        agreement: {
          id: @agreement.id,
          title: @agreement.title,
          description: @agreement.description,
          agreement_number: @agreement.agreement_number,
          status: @agreement.status,
          document_url: @agreement.document_url,
          content: @agreement.content,
          content_type: @agreement.content_type,
          field_placements: @agreement.field_placements,
          expires_at: @agreement.expires_at,
          created_at: @agreement.created_at
        },
        signer: {
          id: @signer.id,
          name: @signer.name,
          email: @signer.email,
          role: @signer.role,
          status: @signer.status,
          signing_order: @signer.signing_order
        },
        all_signers: @agreement.agreement_signers.order(:signing_order).map { |s|
          { name: s.name, role: s.role, status: s.status, signing_order: s.signing_order }
        },
        company: {
          name: company.name,
          logo: company.logo
        }
      }
    end

    # POST /sign/:token/view
    def view_agreement
      @signer.view!(request.remote_ip, request.user_agent)
      render json: { success: true }
    end

    # POST /sign/:token/sign
    def sign
      signature_url = params[:signature_url]
      signature_method = params[:signature_method]

      if @signer.requires_signature? && signature_url.blank? && params[:typed_signature].blank?
        return render json: { error: 'Signature is required' }, status: :unprocessable_entity
      end

      result = @signer.sign!(
        signature_url: signature_url,
        signature_method: signature_method,
        initials_url: params[:initials_url],
        initials_method: params[:initials_method],
        typed_signature: params[:typed_signature],
        typed_initials: params[:typed_initials],
        signature_font: params[:signature_font],
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )

      if result
        render json: { success: true, agreement_status: @agreement.reload.status }
      else
        render json: { error: 'Unable to sign. This agreement may have already been signed or declined.' }, status: :unprocessable_entity
      end
    end

    # POST /sign/:token/decline
    def decline
      reason = params[:decline_reason] || params[:reason]
      unless reason.present?
        return render json: { error: 'Decline reason is required' }, status: :unprocessable_entity
      end

      if @signer.decline!(reason, request.remote_ip, request.user_agent)
        render json: { success: true }
      else
        render json: { error: 'Unable to decline' }, status: :unprocessable_entity
      end
    end

    # GET /sign/:token/download
    def download
      url = @agreement.status == Agreement::STATUS_COMPLETED && @agreement.sealed_document_url.present? ?
        @agreement.sealed_document_url : @agreement.document_url

      unless url.present?
        return render json: { error: 'No document available' }, status: :not_found
      end

      AgreementAuditLog.log!(
        @agreement, AgreementAuditLog::ACTION_DOWNLOADED,
        agreement_signer: @signer,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        performed_by: @signer
      )

      render json: { url: url }
    end

    private

    def find_signer
      @signer = AgreementSigner.find_by!(access_token: params[:token])
      @agreement = @signer.agreement
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Agreement not found or link has expired' }, status: :not_found
    end

    def validate_agreement_status
      if @agreement.status.in?(%w[voided expired completed declined])
        render json: {
          error: "This agreement is #{@agreement.status}",
          status: @agreement.status
        }, status: :gone
      end
    end
  end
end
