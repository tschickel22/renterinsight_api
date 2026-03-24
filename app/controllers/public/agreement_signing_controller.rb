module Public
  class AgreementSigningController < ApplicationController
    skip_before_action :authenticate
    before_action :find_signer
    before_action :validate_agreement_status, except: [:show, :download]

    # GET /sign/:token
    def show
      company = @agreement.company

      # Determine signer's index in the ordered list (matches field_placements signerIndex)
      ordered_signers = @agreement.agreement_signers.order(:signing_order, :id)
      current_signer_index = ordered_signers.index { |s| s.id == @signer.id } || 0

      # Resolve branding waterfall: Location → Company → Platform
      branding = resolve_branding(company, @agreement.location_id)

      # Resolve effective document URL: sealed (completed) > merged PDF > single upload > first from array
      effective_doc_url = if @agreement.status == Agreement::STATUS_COMPLETED && @agreement.sealed_document_url.present?
        @agreement.sealed_document_url
      else
        @agreement.document_url.presence ||
          (@agreement.document_urls.is_a?(Array) ? @agreement.document_urls.first : nil)
      end

      render json: {
        agreement: {
          id: @agreement.id,
          title: @agreement.title,
          description: @agreement.description,
          agreement_number: @agreement.agreement_number,
          status: @agreement.status,
          document_url: effective_doc_url,
          document_urls: @agreement.document_urls,
          content: @agreement.content,
          content_type: @agreement.content_type || (@agreement.document_urls.present? ? 'upload' : 'editor'),
          field_placements: @agreement.merge_field_placements,
          merge_field_values: build_combined_merge_values,
          message_to_signers: @agreement.message_to_signers,
          expires_at: @agreement.expires_at,
          created_at: @agreement.created_at
        },
        signer: {
          id: @signer.id,
          name: @signer.name,
          email: @signer.email,
          role: @signer.role,
          status: @signer.status,
          signing_order: @signer.signing_order,
          signer_index: current_signer_index,
          signed_at: @signer.signed_at
        },
        all_signers: ordered_signers.map { |s|
          { id: s.id, name: s.name, role: s.role, status: s.status, signing_order: s.signing_order, signed_at: s.signed_at }
        },
        company: {
          name: branding[:company_name],
          logo: branding[:logo_url],
          primary_color: branding[:primary_color]
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
      signature_url = params[:signature_url] || params[:signature_data]
      signature_method = params[:signature_method]

      if @signer.requires_signature? && signature_url.blank? && params[:typed_signature].blank?
        return render json: { error: 'Signature is required' }, status: :unprocessable_entity
      end

      result = @signer.sign!(
        signature_url: signature_url,
        signature_method: signature_method,
        initials_url: params[:initials_url] || params[:initials_data],
        initials_method: params[:initials_method],
        typed_signature: params[:typed_signature],
        typed_initials: params[:typed_initials],
        signature_font: params[:signature_font],
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )

      # Save field values filled by this signer (text inputs, checkboxes, etc.)
      if result && params[:field_values].present?
        existing = @agreement.merge_field_values || {}
        signer_values = params[:field_values].to_unsafe_h rescue params[:field_values].to_h
        @agreement.update(merge_field_values: existing.merge(signer_values))
      end

      if result
        agreement = @agreement.reload
        completed = agreement.status == Agreement::STATUS_COMPLETED
        render json: {
          success: true,
          agreement_status: agreement.status,
          completed: completed,
          message: completed ?
            'All signers have signed. Your completed document is ready for download.' :
            'Thank you for signing! You will receive the fully signed document by email once all signers have completed.'
        }
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
      unless @agreement.status == Agreement::STATUS_COMPLETED
        return render json: {
          error: 'Document not ready yet',
          message: 'The signed document will be available once all signers have completed. You will receive it by email.',
          agreement_status: @agreement.status
        }, status: :accepted
      end

      # If completed but not yet sealed, the background job is still running
      unless @agreement.sealed_document_url.present?
        return render json: {
          error: 'Document is being sealed',
          message: 'The signed document is being prepared. Please try again in a few moments.',
          agreement_status: @agreement.status,
          retry_after: 3
        }, status: :accepted
      end

      url = @agreement.sealed_document_url

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

    def resolve_branding(company, location_id)
      branding = { company_name: 'Platform DMS', logo_url: nil, primary_color: '#3b82f6' }

      # Platform
      platform_b = Setting.get('Platform', 0, 'branding', {})
      merge_brand!(branding, platform_b) if platform_b.is_a?(Hash)

      # Company
      if company
        company_b = Setting.get('Company', company.id, 'branding', {})
        merge_brand!(branding, company_b) if company_b.is_a?(Hash)
        branding[:company_name] = company.name if company.name.present?
      end

      # Location (highest priority)
      if location_id.present?
        location_b = Setting.get('Location', location_id, 'branding', {})
        merge_brand!(branding, location_b) if location_b.is_a?(Hash)
      end

      # Ensure logo is absolute URL
      if branding[:logo_url].present? && !branding[:logo_url].start_with?('http')
        api_base = ENV['RAILS_API_URL'] || 'https://localhost:3001'
        branding[:logo_url] = "#{api_base}#{branding[:logo_url]}"
      end

      branding
    end

    # Combine ALL value sources into one hash for the signing view:
    # 1. Live-resolved merge fields from linked entities (most reliable)
    # 2. Stored merge_field_values (fallback)
    # 3. Custom field values with 'custom.' prefix
    def build_combined_merge_values
      combined = {}
      company = @agreement.company

      # 1. Resolve live values from linked entities
      contact = company.contacts.find_by(id: @agreement.contact_id) if @agreement.contact_id.present?
      account = company.accounts.find_by(id: @agreement.account_id) if @agreement.account_id.present?
      deal = company.deals.find_by(id: @agreement.deal_id) if @agreement.deal_id.present?
      vehicle = nil
      if deal&.respond_to?(:vehicle_id) && deal.vehicle_id.present?
        vehicle = company.vehicles.find_by(id: deal.vehicle_id)
      end

      if contact
        combined['contact.first_name'] = contact.first_name.to_s
        combined['contact.last_name'] = contact.last_name.to_s
        combined['contact.full_name'] = [contact.first_name, contact.last_name].compact.join(' ')
        combined['contact.email'] = contact.email.to_s
        combined['contact.phone'] = contact.phone.to_s
        combined['contact.mobile_phone'] = (contact.try(:mobile_phone) || contact.try(:cell_phone)).to_s
        combined['contact.street'] = (contact.try(:street) || contact.try(:address)).to_s
        combined['contact.city'] = contact.try(:city).to_s
        combined['contact.state'] = contact.try(:state).to_s
        combined['contact.zip'] = (contact.try(:zip) || contact.try(:postal_code)).to_s
      end

      if account
        combined['account.name'] = account.name.to_s
      end

      if deal
        combined['deal.name'] = (deal.respond_to?(:title) ? deal.title : deal.name).to_s
        combined['deal.amount'] = (deal.respond_to?(:amount) ? deal.amount : deal.try(:value)).to_s
        combined['deal.owner_name'] = deal.respond_to?(:owner) ? [deal.owner&.first_name, deal.owner&.last_name].compact.join(' ') : ''
      end

      if vehicle
        combined['vehicle.make'] = vehicle.try(:make).to_s
        combined['vehicle.model'] = vehicle.try(:model).to_s
        combined['vehicle.year'] = vehicle.try(:year).to_s
        combined['vehicle.vin'] = (vehicle.try(:vin) || vehicle.try(:serial_number)).to_s
        combined['vehicle.stock_number'] = vehicle.try(:stock_number).to_s
        combined['vehicle.condition'] = vehicle.try(:condition)&.titleize.to_s
        combined['vehicle.sections'] = vehicle.try(:sections).to_s
        combined['vehicle.bedrooms'] = vehicle.try(:bedrooms).to_s
        combined['vehicle.bathrooms'] = (vehicle.try(:bathrooms) || vehicle.try(:baths)).to_s
        combined['vehicle.length'] = vehicle.try(:length).to_s
        combined['vehicle.width'] = vehicle.try(:width).to_s
        combined['vehicle.exterior_color'] = (vehicle.try(:exterior_color) || vehicle.try(:color)).to_s
        combined['vehicle.price'] = (vehicle.try(:price) || vehicle.try(:msrp) || vehicle.try(:sale_price)).to_s
      end

      combined['company.name'] = company.name.to_s
      combined['company.email'] = company.try(:email).to_s
      combined['company.phone'] = company.try(:phone).to_s
      combined['date.today'] = Date.today.strftime('%m/%d/%Y')
      combined['date.current_year'] = Date.today.year.to_s

      # 2. Merge stored values (fill in anything not resolved live)
      if @agreement.merge_field_values.present?
        @agreement.merge_field_values.each do |key, value|
          next if value.nil? || value.to_s.strip.empty?
          combined[key] = value.to_s unless combined[key].present?
        end
      end

      # 3. Add custom field values with 'custom.' prefix
      if @agreement.custom_field_values.present?
        @agreement.custom_field_values.each do |key, value|
          next if value.nil? || value.to_s.strip.empty?
          combined["custom.#{key}"] = value.to_s
        end
      end

      # Remove empty string values
      combined.reject { |_, v| v.blank? }
    end

    def merge_brand!(target, source)
      s = source.stringify_keys
      target[:company_name]  = s['companyName']  if s['companyName'].present?
      target[:logo_url]      = s['logo']         if s['logo'].present?
      target[:primary_color] = s['primaryColor'] if s['primaryColor'].present?
    end
  end
end
