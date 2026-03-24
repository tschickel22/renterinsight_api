module Api
  module Portal
    class AgreementsController < BaseController

      # GET /api/portal/agreements
      def index
        signer_agreement_ids = AgreementSigner
          .where(email: current_contact.email)
          .pluck(:agreement_id)
          .uniq

        agreements = Agreement.where(id: signer_agreement_ids).active.order(created_at: :desc)

        # Filter by status
        agreements = agreements.where(status: params[:status]) if params[:status].present?

        # Paginate
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 20).to_i, 100].min
        total = agreements.count
        agreements = agreements.offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: agreements.map { |a| portal_agreement_json(a) },
          meta: {
            total: total,
            page: page,
            per_page: per_page,
            total_pages: (total.to_f / per_page).ceil
          }
        }
      end

      # GET /api/portal/agreements/:id
      def show
        agreement = find_portal_agreement

        signers = agreement.agreement_signers.order(:signing_order)
        audit_logs = agreement.agreement_audit_logs.order(created_at: :asc)

        render json: portal_agreement_json(agreement).merge(
          signing_progress: agreement.signing_progress,
          signers: signers.map { |s|
            { name: s.name, role: s.role, status: s.status, signed_at: s.signed_at }
          },
          audit_trail: audit_logs.map { |l|
            { action: l.action, created_at: l.created_at }
          }
        )
      end

      # GET /api/portal/agreements/:id/download
      def download
        agreement = find_portal_agreement

        if agreement.status == Agreement::STATUS_COMPLETED
          unless agreement.sealed_document_url.present?
            return render json: {
              error: 'Document is being sealed',
              message: 'The signed document is being prepared. Please try again in a few moments.',
              retry_after: 3
            }, status: :accepted
          end
          url = agreement.sealed_document_url
        else
          url = agreement.document_url
        end

        unless url.present?
          return render json: { error: 'No document available' }, status: :not_found
        end

        # Find the signer record for this contact
        signer = agreement.agreement_signers.find_by(email: current_contact.email)

        AgreementAuditLog.log!(
          agreement, AgreementAuditLog::ACTION_DOWNLOADED,
          agreement_signer: signer,
          ip_address: request.remote_ip,
          user_agent: request.user_agent,
          performed_by: signer
        )

        render json: { url: url }
      end

      private

      def find_portal_agreement
        signer_agreement_ids = AgreementSigner
          .where(email: current_contact.email)
          .pluck(:agreement_id)

        Agreement.where(id: signer_agreement_ids).active.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Agreement not found' }, status: :not_found
      end

      def portal_agreement_json(agreement)
        my_signer = agreement.agreement_signers.find_by(email: current_contact.email)

        effective_doc_url = if agreement.status == Agreement::STATUS_COMPLETED && agreement.sealed_document_url.present?
          agreement.sealed_document_url
        else
          agreement.document_url
        end

        json = {
          id: agreement.id,
          title: agreement.title,
          agreement_number: agreement.agreement_number,
          status: agreement.status,
          category: agreement.category,
          document_url: effective_doc_url,
          sent_at: agreement.sent_at,
          completed_at: agreement.completed_at,
          expires_at: agreement.expires_at,
          created_at: agreement.created_at,
          my_signer_status: my_signer&.status,
          my_signer_role: my_signer&.role
        }

        # Include signing URL if the signer still needs to sign
        if my_signer && %w[pending viewed].include?(my_signer.status)
          json[:signing_url] = my_signer.signing_url
          json[:signing_access_token] = my_signer.access_token
        end

        json
      end
    end
  end
end
