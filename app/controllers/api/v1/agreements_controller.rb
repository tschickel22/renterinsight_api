module Api
  module V1
    class AgreementsController < ApplicationController
      before_action :set_company_scope
      before_action :set_agreement, only: [
        :show, :update, :destroy, :send_agreement, :void, :remind, :remind_signer,
        :duplicate, :save_as_template, :audit_log, :download, :certificate, :prepare_signature,
        :add_signer, :update_signer, :remove_signer, :add_attachment, :remove_attachment
      ]

      # GET /api/v1/agreements
      def index
        return unless authorize_action!('agreements', 'read')

        agreements = @company.agreements.active

        # RBAC location filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service&.accessible_location_ids
          agreements = agreements.where(location_id: location_ids) if location_ids&.any?
        end

        # Location selector filter
        agreements = agreements.for_current_location if Current.location_filtered?

        # Entity filter (explicit columns)
        if params[:entity_type].present? && params[:entity_id].present?
          agreements = agreements.for_entity(params[:entity_type], params[:entity_id])
        end
        agreements = agreements.for_contact(params[:contact_id]) if params[:contact_id].present?
        agreements = agreements.for_account(params[:account_id]) if params[:account_id].present?
        agreements = agreements.for_deal(params[:deal_id]) if params[:deal_id].present?

        # Category & prepared_by filters (apply before stats)
        agreements = agreements.by_category(params[:category]) if params[:category].present?
        agreements = agreements.where(prepared_by_id: params[:prepared_by_id]) if params[:prepared_by_id].present?

        # Date range filters (apply before stats — tiles reflect date range)
        if params[:created_after].present?
          agreements = agreements.where('agreements.created_at >= ?', params[:created_after])
        end
        if params[:created_before].present?
          agreements = agreements.where('agreements.created_at <= ?', params[:created_before])
        end
        if params[:expires_before].present?
          agreements = agreements.where('agreements.expires_at <= ?', params[:expires_before])
        end

        # Stats BEFORE status filter & search — 1 GROUP BY query instead of 9 COUNT queries
        status_counts = agreements.group(:status).count
        stats = {
          total: status_counts.values.sum,
          draft: status_counts['draft'] || 0,
          sent: status_counts['sent'] || 0,
          viewed: status_counts['viewed'] || 0,
          partially_signed: status_counts['partially_signed'] || 0,
          completed: status_counts['completed'] || 0,
          expired: status_counts['expired'] || 0,
          voided: status_counts['voided'] || 0,
          declined: status_counts['declined'] || 0
        }

        # Status filter AFTER stats (clicking a tile doesn't change tile counts)
        agreements = agreements.by_status(params[:status]) if params[:status].present?

        # Search AFTER stats
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          agreements = agreements.where(
            "agreements.title ILIKE ? OR agreements.agreement_number ILIKE ?",
            search_term, search_term
          )
        end

        # Sort
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? 'asc' : 'desc'
        agreements = agreements.order(sort_by => sort_order)

        # Paginate
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        total = agreements.count
        agreements = agreements
          .offset((page - 1) * per_page)
          .limit(per_page)
          .includes(:agreement_signers, :prepared_by, :location, :contact, :account, :deal)

        render json: {
          items: agreements.map { |a| agreement_json(a) },
          meta: {
            total: total,
            page: page,
            per_page: per_page,
            total_pages: (total.to_f / per_page).ceil,
            stats: stats
          }
        }
      rescue => e
        Rails.logger.error "Error in agreements#index: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # GET /api/v1/agreements/:id
      def show
        return unless authorize_action!('agreements', 'read')

        render json: agreement_json(@agreement, detailed: true)
      end

      # POST /api/v1/agreements
      def create
        return unless authorize_action!('agreements', 'create')

        agreement = @company.agreements.new(agreement_params)
        agreement.prepared_by = current_user
        agreement.location_id ||= Current.location_id

        # RBAC fallback for location
        if agreement.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service&.accessible_location_ids
          agreement.location_id = location_ids&.first
        end

        # Set default expiry
        agreement.expires_at ||= 30.days.from_now

        # Copy template data if template_id provided
        if params.dig(:agreement, :agreement_template_id).present?
          template = @company.agreement_templates.active.find_by(id: params[:agreement][:agreement_template_id])
          if template
            agreement.agreement_template = template
            agreement.content = template.content if agreement.content.blank?
            agreement.document_url = template.document_url if agreement.document_url.blank?
            agreement.content_type = template.template_type if agreement.content_type.blank?
            agreement.field_placements = template.field_placements if agreement.field_placements.blank?
            agreement.merge_field_values = template.merge_fields if agreement.merge_field_values.blank?
          end
        end

        if agreement.save
          # Create initial signers if provided
          sync_signers(agreement) if params.dig(:agreement, :signers).present?

          render json: agreement_json(agreement.reload, detailed: true), status: :created
        else
          render json: { errors: agreement.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error in agreements#create: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/agreements/:id
      def update
        return unless authorize_action!('agreements', 'update')

        unless @agreement.can_edit?
          return render json: { error: 'Agreement can only be edited in draft status' }, status: :unprocessable_entity
        end

        if @agreement.update(agreement_params)
          # Sync signers if provided (full replace while in draft)
          sync_signers(@agreement) if params.dig(:agreement, :signers).present?

          render json: agreement_json(@agreement.reload, detailed: true)
        else
          render json: { errors: @agreement.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/agreements/:id
      def destroy
        return unless authorize_action!('agreements', 'delete')

        unless @agreement.status == Agreement::STATUS_DRAFT
          return render json: { error: 'Only draft agreements can be deleted' }, status: :unprocessable_entity
        end

        @agreement.update!(is_deleted: true)
        head :no_content
      end

      # POST /api/v1/agreements/:id/send_agreement
      def send_agreement
        return unless authorize_action!('agreements', 'update')

        unless @agreement.can_send?
          return render json: { error: 'Agreement cannot be sent. Ensure it is in draft status with at least one signer.' }, status: :unprocessable_entity
        end

        if @agreement.send_to_signers!(current_user)
          SendAgreementJob.perform_later(@agreement.id) if defined?(SendAgreementJob)
          render json: agreement_json(@agreement.reload, detailed: true)
        else
          render json: { error: 'Failed to send agreement' }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/agreements/:id/void
      def void
        return unless authorize_action!('agreements', 'update')

        reason = params[:void_reason] || params[:reason]
        unless reason.present?
          return render json: { error: 'Void reason is required' }, status: :unprocessable_entity
        end

        if @agreement.void!(current_user, reason)
          render json: agreement_json(@agreement.reload, detailed: true)
        else
          render json: { error: 'Agreement cannot be voided in its current status' }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/agreements/:id/remind
      def remind
        return unless authorize_action!('agreements', 'update')

        @agreement.pending_signers.each do |signer|
          @agreement.agreement_reminders.create!(
            agreement_signer: signer,
            scheduled_at: Time.current,
            reminder_type: 'manual',
            channel: 'email'
          )
          SendAgreementReminderJob.perform_later(@agreement.id, signer.id)
        end

        AgreementAuditLog.log!(@agreement, AgreementAuditLog::ACTION_REMINDER_SENT, performed_by: current_user)
        render json: { success: true, message: 'Reminders queued for all pending signers' }
      end

      # POST /api/v1/agreements/:id/remind_signer
      def remind_signer
        return unless authorize_action!('agreements', 'update')

        signer = @agreement.agreement_signers.find(params[:signer_id])

        @agreement.agreement_reminders.create!(
          agreement_signer: signer,
          scheduled_at: Time.current,
          reminder_type: 'manual',
          channel: 'email'
        )
        SendAgreementReminderJob.perform_later(@agreement.id, signer.id)

        AgreementAuditLog.log!(@agreement, AgreementAuditLog::ACTION_REMINDER_SENT, performed_by: current_user, metadata: { signer_id: signer.id })
        render json: { success: true, message: "Reminder sent to #{signer.name}" }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Signer not found' }, status: :not_found
      end

      # POST /api/v1/agreements/:id/duplicate
      def duplicate
        return unless authorize_action!('agreements', 'create')

        new_agreement = @agreement.duplicate!(current_user)
        render json: agreement_json(new_agreement, detailed: true), status: :created
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/agreements/:id/save_as_template
      def save_as_template
        return unless authorize_action!('agreements', 'create')

        name = params[:name]&.strip
        return render json: { error: 'Template name is required' }, status: :unprocessable_entity if name.blank?

        # Find or create category matching the agreement's category
        category = @company.agreement_categories.find_by(name: @agreement.category) if @agreement.category.present?

        # Map agreement content_type to template_type (upload/editor)
        template_type = case @agreement.content_type
                        when 'editor', 'html' then 'editor'
                        else 'upload'
                        end

        # Build signer index → generic label map BEFORE creating template
        # signerIndex in field_placements is 0-based, matches signing_order - 1
        ordered_signers = @agreement.agreement_signers.order(:signing_order).to_a
        signer_labels = ordered_signers.each_with_index.map do |s, i|
          [i, s.role.titleize]  # e.g. 0 => "Signer", 1 => "Signer"
        end.to_h

        # Normalize field placements — strip actual signer names from fieldLabel
        # e.g. "Signature — Tom Admin" => "Signature — Signer 1"
        normalize_placements = ->(placements) {
          return placements unless placements.is_a?(Array)
          placements.map do |p|
            p = p.is_a?(Hash) ? p.dup : p.to_h
            if p['isSignerField'] || p[:isSignerField]
              idx = (p['signerIndex'] || p[:signerIndex] || 0).to_i
              generic_label = "Signer #{idx + 1}"
              field_label = p['fieldLabel'] || p[:fieldLabel] || ''
              # Replace everything after " — " (em dash or regular dash) with generic label
              normalized = field_label.sub(/\s*[—\-–]\s*.+$/, " — #{generic_label}")
              p['fieldLabel'] = normalized
              p[:fieldLabel] = normalized if p.key?(:fieldLabel)
            end
            p
          end
        }

        normalized_field_placements = normalize_placements.call(@agreement.field_placements)
        normalized_merge_field_placements = normalize_placements.call(@agreement.merge_field_placements)

        template = @company.agreement_templates.new(
          name: name,
          description: params[:description]&.strip,
          template_type: template_type,
          content: @agreement.content,
          document_url: @agreement.document_url,
          field_placements: normalized_field_placements,
          merge_fields: @agreement.merge_field_values,
          agreement_category: category,
          status: 'draft',
          created_by: current_user
        )

        # Set JSONB columns that may have been added via migration
        template.document_urls = @agreement.document_urls if template.respond_to?(:document_urls=)
        template.merge_field_placements = normalized_merge_field_placements if template.respond_to?(:merge_field_placements=)

        # Copy default signers from agreement signers (structure only, no personal data)
        if ordered_signers.any?
          template.default_signers = ordered_signers
            .each_with_index
            .map { |s, i| { role: s.role, order_index: i, label: "Signer #{i + 1}" } }
        end

        if template.save
          AgreementAuditLog.log!(@agreement, 'saved_as_template', performed_by: current_user,
            metadata: { template_id: template.id, template_name: template.name })
          render json: {
            id: template.id,
            name: template.name,
            description: template.description,
            status: template.status,
            created_at: template.created_at
          }, status: :created
        else
          render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error in agreements#save_as_template: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/agreements/:id/audit_log
      def audit_log
        return unless authorize_action!('agreements', 'read')

        logs = @agreement.agreement_audit_logs.order(created_at: :asc).includes(:agreement_signer)

        render json: {
          items: logs.map { |log|
            # Resolve actor name from polymorphic performed_by
            actor_name = if log.agreement_signer.present?
              log.agreement_signer.name
            elsif log.performed_by.is_a?(User)
              log.performed_by.name rescue nil
            elsif log.performed_by.is_a?(AgreementSigner)
              log.performed_by.name rescue nil
            end

            {
              id: log.id,
              action: log.action,
              ip_address: log.ip_address,
              geolocation: log.geolocation,
              performed_by_type: log.performed_by_type,
              performed_by_id: log.performed_by_id,
              performed_by_name: actor_name,
              signer_name: log.agreement_signer&.name,
              metadata: log.metadata,
              created_at: log.created_at
            }
          }
        }
      end

      # GET /api/v1/agreements/:id/download
      def download
        return unless authorize_action!('agreements', 'read')

        effective_doc_url = @agreement.document_url.presence ||
          (@agreement.document_urls.is_a?(Array) ? @agreement.document_urls.first : nil)

        url = @agreement.status == Agreement::STATUS_COMPLETED && @agreement.sealed_document_url.present? ?
          @agreement.sealed_document_url : effective_doc_url

        unless url.present?
          return render json: { error: 'No document available' }, status: :not_found
        end

        AgreementAuditLog.log!(@agreement, AgreementAuditLog::ACTION_DOWNLOADED, performed_by: current_user)
        render json: { url: url, filename: "#{@agreement.agreement_number}.pdf" }
      end

      # GET /api/v1/agreements/:id/certificate
      def certificate
        return unless authorize_action!('agreements', 'read')

        unless @agreement.status == Agreement::STATUS_COMPLETED
          return render json: { error: 'Certificate only available for completed agreements' }, status: :unprocessable_entity
        end

        logs = @agreement.agreement_audit_logs.order(created_at: :asc)
        signers = @agreement.agreement_signers.where(role: [AgreementSigner::ROLE_SIGNER, AgreementSigner::ROLE_COUNTER_SIGNER])

        render json: {
          agreement_number: @agreement.agreement_number,
          title: @agreement.title,
          completed_at: @agreement.completed_at,
          signers: signers.map { |s|
            {
              name: s.name,
              email: s.email,
              role: s.role,
              signed_at: s.signed_at,
              ip_address: s.ip_address,
              signature_method: s.signature_method,
              signature_hash: s.signature_hash
            }
          },
          audit_trail: logs.map { |l|
            { action: l.action, created_at: l.created_at, ip_address: l.ip_address }
          }
        }
      end

      # POST /api/v1/agreements/:id/prepare_signature
      def prepare_signature
        return unless authorize_action!('agreements', 'update')

        unless @agreement.can_edit?
          return render json: { error: 'Agreement must be in draft status' }, status: :unprocessable_entity
        end

        # Find or create preparer signer for current user
        preparer = @agreement.agreement_signers.find_or_initialize_by(
          email: current_user.email,
          role: AgreementSigner::ROLE_PREPARER
        )
        preparer.name = current_user.name
        preparer.save!

        preparer.sign!(
          signature_url: params[:signature_url],
          signature_method: params[:signature_method],
          initials_url: params[:initials_url],
          initials_method: params[:initials_method],
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )

        render json: agreement_json(@agreement.reload, detailed: true)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/agreements/stats
      def stats
        return unless authorize_action!('agreements', 'read')

        agreements = @company.agreements.active

        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service&.accessible_location_ids
          agreements = agreements.where(location_id: location_ids) if location_ids&.any?
        end

        agreements = agreements.for_current_location if Current.location_filtered?

        status_counts = agreements.group(:status).count

        render json: {
          total: agreements.count,
          draft: status_counts['draft'] || 0,
          sent: status_counts['sent'] || 0,
          viewed: status_counts['viewed'] || 0,
          partially_signed: status_counts['partially_signed'] || 0,
          completed: status_counts['completed'] || 0,
          expired: status_counts['expired'] || 0,
          voided: status_counts['voided'] || 0,
          declined: status_counts['declined'] || 0,
          this_month: agreements.where('agreements.created_at >= ?', Time.current.beginning_of_month).count,
          expiring_soon: agreements.expiring_soon(7).count
        }
      end

      # GET /api/v1/agreements/entity_context
      def entity_context
        return unless authorize_action!('agreements', 'read')

        entity_type = params[:entity_type]
        entity_id = params[:entity_id]

        result = { contacts: [], account: nil, deals: [] }

        case entity_type
        when 'Contact'
          contact = @company.contacts.find_by(id: entity_id)
          if contact
            result[:contacts] = [{ id: contact.id, name: [contact.first_name, contact.last_name].compact.join(' '), email: contact.email, phone: contact.phone }]
            if contact.account_id.present?
              account = @company.accounts.find_by(id: contact.account_id)
              result[:account] = { id: account.id, name: account.name } if account
            end
            # Find deals associated with this contact
            if @company.respond_to?(:deals)
              deals = @company.deals.where(contact_id: contact.id).where(is_deleted: [false, nil])
              result[:deals] = deals.map { |d| { id: d.id, name: d.respond_to?(:title) ? d.title : d.name, stage: d.respond_to?(:stage) ? d.stage : nil } }
            end
          end
        when 'Account'
          account = @company.accounts.find_by(id: entity_id)
          if account
            result[:account] = { id: account.id, name: account.name }
            contacts = @company.contacts.where(account_id: account.id).where(is_deleted: [false, nil]).limit(50)
            result[:contacts] = contacts.map { |c| { id: c.id, name: [c.first_name, c.last_name].compact.join(' '), email: c.email, phone: c.phone } }
            if @company.respond_to?(:deals)
              deals = @company.deals.where(account_id: account.id).where(is_deleted: [false, nil])
              result[:deals] = deals.map { |d| { id: d.id, name: d.respond_to?(:title) ? d.title : d.name, stage: d.respond_to?(:stage) ? d.stage : nil } }
            end
          end
        when 'Deal'
          if @company.respond_to?(:deals)
            deal = @company.deals.find_by(id: entity_id)
            if deal
              result[:deals] = [{ id: deal.id, name: deal.respond_to?(:title) ? deal.title : deal.name, stage: deal.respond_to?(:stage) ? deal.stage : nil }]
              if deal.respond_to?(:account_id) && deal.account_id.present?
                account = @company.accounts.find_by(id: deal.account_id)
                result[:account] = { id: account.id, name: account.name } if account
              end
              if deal.respond_to?(:contact_id) && deal.contact_id.present?
                contact = @company.contacts.find_by(id: deal.contact_id)
                result[:contacts] = [{ id: contact.id, name: [contact.first_name, contact.last_name].compact.join(' '), email: contact.email, phone: contact.phone }] if contact
              elsif result[:account].present?
                # Load account's contacts as signer options
                contacts = @company.contacts.where(account_id: result[:account][:id]).where(is_deleted: [false, nil]).limit(50)
                result[:contacts] = contacts.map { |c| { id: c.id, name: [c.first_name, c.last_name].compact.join(' '), email: c.email, phone: c.phone } }
              end
            end
          end
        end

        render json: result
      rescue => e
        Rails.logger.error "Error in agreements#entity_context: #{e.message}"
        render json: { contacts: [], account: nil, deals: [] }
      end

      # === Nested Signer Actions ===

      # POST /api/v1/agreements/:id/signers
      def add_signer
        return unless authorize_action!('agreements', 'update')

        unless %w[draft sent].include?(@agreement.status)
          return render json: { error: 'Signers can only be added to draft or sent agreements' }, status: :unprocessable_entity
        end

        signer = @agreement.agreement_signers.new(signer_params)
        if signer.save
          AgreementAuditLog.log!(@agreement, AgreementAuditLog::ACTION_SIGNER_ADDED, performed_by: current_user, metadata: { signer_name: signer.name })
          render json: agreement_json(@agreement.reload, detailed: true), status: :created
        else
          render json: { errors: signer.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/agreements/:id/signers/:signer_id
      def update_signer
        return unless authorize_action!('agreements', 'update')

        unless @agreement.can_edit?
          return render json: { error: 'Signers can only be updated in draft status' }, status: :unprocessable_entity
        end

        signer = @agreement.agreement_signers.find(params[:signer_id])
        if signer.update(signer_params)
          render json: agreement_json(@agreement.reload, detailed: true)
        else
          render json: { errors: signer.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Signer not found' }, status: :not_found
      end

      # DELETE /api/v1/agreements/:id/signers/:signer_id
      def remove_signer
        return unless authorize_action!('agreements', 'update')

        unless @agreement.can_edit?
          return render json: { error: 'Signers can only be removed in draft status' }, status: :unprocessable_entity
        end

        signer = @agreement.agreement_signers.find(params[:signer_id])
        signer_name = signer.name
        signer.destroy!
        AgreementAuditLog.log!(@agreement, AgreementAuditLog::ACTION_SIGNER_REMOVED, performed_by: current_user, metadata: { signer_name: signer_name })
        render json: agreement_json(@agreement.reload, detailed: true)
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Signer not found' }, status: :not_found
      end

      # === Nested Attachment Actions ===

      # POST /api/v1/agreements/:id/attachments
      def add_attachment
        return unless authorize_action!('agreements', 'update')

        file = params[:file]

        if file.present?
          # File-based attachment — upload to S3
          if file.size > 25.megabytes
            return render json: { error: 'File size exceeds 25MB limit' }, status: :unprocessable_entity
          end

          begin
            s3_service = S3UploadService.new
            folder = "agreements/#{@company.id}/#{@agreement.id}/attachments"
            result = s3_service.upload(file, folder: folder)

            attachment = @agreement.agreement_attachments.new(
              filename: file.original_filename,
              file_url: result[:url],
              file_content_type: file.content_type,
              byte_size: file.size,
              attached_by: current_user
            )
          rescue => e
            Rails.logger.error "S3 upload error: #{e.message}"
            return render json: { error: 'Failed to upload file' }, status: :unprocessable_entity
          end
        else
          # Entity-link attachment
          attachment = @agreement.agreement_attachments.new(
            attachable_type: params[:attachable_type],
            attachable_id: params[:attachable_id],
            attached_by: current_user
          )
        end

        if attachment.save
          AgreementAuditLog.log!(@agreement, AgreementAuditLog::ACTION_ATTACHMENT_ADDED, performed_by: current_user, metadata: { filename: attachment.filename })
          render json: agreement_json(@agreement.reload, detailed: true), status: :created
        else
          render json: { errors: attachment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/agreements/:id/attachments/:attachment_id
      def remove_attachment
        return unless authorize_action!('agreements', 'update')

        attachment = @agreement.agreement_attachments.find(params[:attachment_id])
        attachment.destroy!
        AgreementAuditLog.log!(@agreement, AgreementAuditLog::ACTION_ATTACHMENT_REMOVED, performed_by: current_user)
        render json: agreement_json(@agreement.reload, detailed: true)
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Attachment not found' }, status: :not_found
      end

      private

      def set_agreement
        @agreement = @company.agreements.active.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Agreement not found' }, status: :not_found
      end

      def agreement_params
        permitted = params.require(:agreement).permit(
          :title, :description, :category, :document_url, :content,
          :content_type, :expires_at, :reminder_frequency_days, :location_id,
          :contact_id, :account_id, :deal_id,
          :delivery_method, :signing_order, :message_to_signers
        )

        # Handle JSONB fields - must use permit!/to_unsafe_h for arbitrary nested structures
        # Rails 8 raises ActionController::UnfilteredParameters without this
        raw = params[:agreement].to_unsafe_h

        permitted[:field_placements] = raw[:field_placements] if raw[:field_placements].present?
        permitted[:merge_field_values] = raw[:merge_field_values] if raw[:merge_field_values].present?
        permitted[:merge_field_placements] = raw[:merge_field_placements] if raw[:merge_field_placements].present?
        permitted[:metadata] = raw[:metadata] if raw[:metadata].present?
        permitted[:document_urls] = raw[:document_urls] if raw[:document_urls].present?

        permitted
      end

      def signer_params
        params.require(:signer).permit(:name, :email, :phone, :role, :signing_order, :signable_type, :signable_id)
      end

      # Sync signers from the frontend payload
      # In draft status: full replace (delete all, recreate)
      # Preserves existing signers that have already been sent/signed (non-draft)
      def sync_signers(agreement)
        signers_data = params[:agreement][:signers]
        return if signers_data.blank?

        if agreement.status == Agreement::STATUS_DRAFT
          # Draft: safe to do full replace
          agreement.agreement_signers.destroy_all

          signers_data.each do |sd|
            sd = sd.to_unsafe_h if sd.respond_to?(:to_unsafe_h)

            # Determine signable (polymorphic link to Contact)
            signable_type = sd['signable_type'] || (sd['contact_id'].present? ? 'Contact' : nil)
            signable_id = sd['signable_id'] || sd['contact_id']

            agreement.agreement_signers.create!(
              name: sd['name'],
              email: sd['email'],
              phone: sd['phone'],
              role: sd['role'] || 'signer',
              signing_order: sd['signing_order'] || 1,
              signable_type: signable_type,
              signable_id: signable_id
            )
          end
        else
          # Non-draft: only add NEW signers (don't touch existing)
          existing_emails = agreement.agreement_signers.pluck(:email).map(&:downcase)

          signers_data.each do |sd|
            sd = sd.to_unsafe_h if sd.respond_to?(:to_unsafe_h)
            next if existing_emails.include?(sd['email']&.downcase)

            agreement.agreement_signers.create!(
              name: sd['name'],
              email: sd['email'],
              phone: sd['phone'],
              role: sd['role'] || 'signer',
              signing_order: sd['signing_order'] || 1
            )
          end
        end
      end

      def agreement_json(agreement, detailed: false)
        data = {
          id: agreement.id,
          agreement_number: agreement.agreement_number,
          title: agreement.title,
          description: agreement.description,
          status: agreement.status,
          category: agreement.category,
          content_type: agreement.content_type,
          signing_progress: agreement.signing_progress,
          expires_at: agreement.expires_at,
          sent_at: agreement.sent_at,
          completed_at: agreement.completed_at,
          prepared_by_id: agreement.prepared_by_id,
          prepared_by_name: agreement.prepared_by&.name,
          location_id: agreement.location_id,
          location_name: agreement.location&.name,
          contact_id: agreement.contact_id,
          account_id: agreement.account_id,
          deal_id: agreement.deal_id,
          contact_name: agreement.contact&.respond_to?(:name) ? agreement.contact.name : [agreement.contact&.first_name, agreement.contact&.last_name].compact.join(' '),
          account_name: agreement.account&.name,
          deal_name: agreement.deal&.respond_to?(:title) ? agreement.deal.title : agreement.deal&.name,
          delivery_method: agreement.delivery_method,
          signing_order: agreement.signing_order,
          message_to_signers: agreement.message_to_signers,
          signers_count: agreement.agreement_signers.size,
          signer_names: agreement.agreement_signers
            .select { |s| s.role == 'signer' }
            .sort_by(&:signing_order)
            .map(&:name),
          created_at: agreement.created_at,
          updated_at: agreement.updated_at
        }

        if detailed
          data.merge!(
            content: agreement.content,
            document_url: agreement.document_url,
            sealed_document_url: agreement.sealed_document_url,
            document_urls: agreement.document_urls,
            template_id: agreement.agreement_template_id,
            template_name: agreement.agreement_template&.name,
            field_placements: agreement.field_placements,
            merge_field_values: agreement.merge_field_values,
            merge_field_placements: agreement.merge_field_placements,
            metadata: agreement.metadata,
            voided_at: agreement.voided_at,
            void_reason: agreement.void_reason,
            declined_at: agreement.declined_at,
            reminder_frequency_days: agreement.reminder_frequency_days,
            version: agreement.version,
            parent_agreement_id: agreement.parent_agreement_id,
            signers: agreement.agreement_signers.order(:signing_order).map { |s|
              {
                id: s.id,
                name: s.name,
                email: s.email,
                phone: s.phone,
                role: s.role,
                status: s.status,
                signing_order: s.signing_order,
                signed_at: s.signed_at,
                viewed_at: s.viewed_at,
                declined_at: s.declined_at,
                signature_method: s.signature_method,
                signing_url: s.signing_url,
                signable_type: s.signable_type,
                signable_id: s.signable_id
              }
            },
            attachments: agreement.agreement_attachments.map { |a|
              {
                id: a.id,
                filename: a.filename,
                file_url: a.file_url,
                content_type: a.file_content_type,
                file_size: a.byte_size,
                byte_size: a.byte_size,
                attachable_type: a.attachable_type,
                attachable_id: a.attachable_id,
                uploaded_by_name: a.attached_by&.name,
                created_at: a.created_at
              }
            },
            recent_audit_logs: agreement.agreement_audit_logs.order(created_at: :desc).limit(20).map { |l|
              {
                id: l.id,
                action: l.action,
                ip_address: l.ip_address,
                signer_name: l.agreement_signer&.name,
                metadata: l.metadata,
                created_at: l.created_at
              }
            }
          )
        end

        data
      end
    end
  end
end
