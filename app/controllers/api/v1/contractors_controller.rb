# frozen_string_literal: true

module Api
  module V1
    class ContractorsController < ApplicationController
      before_action :set_company_scope
      before_action :set_contractor, only: [:show, :update, :destroy, :sms_consent]

      # GET /api/v1/contractors
      def index
        return unless authorize_action!('contractors', 'read')

        contractors = @company.contractors.not_deleted

        # Stats counted BEFORE search (for tiles)
        total_count = contractors.count
        active_count = contractors.active.count
        trade_type_counts = contractors.group(:trade_type).count

        # Filter by vendor_only
        contractors = contractors.vendors if params[:vendor_only] == 'true'

        # Filter by status
        contractors = contractors.where(status: params[:status]) if params[:status].present?

        # Filter by trade_type
        contractors = contractors.by_trade(params[:trade_type]) if params[:trade_type].present?

        # Search on name/contact_name/email/trade_type
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          contractors = contractors.where(
            "name ILIKE ? OR contact_name ILIKE ? OR email ILIKE ? OR trade_type ILIKE ?",
            search_term, search_term, search_term, search_term
          )
        end

        # Count after filters (for pagination)
        filtered_count = contractors.count

        # Paginate
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min
        contractors = contractors.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: contractors.map { |c| contractor_json(c) },
          meta: {
            total: filtered_count,
            page: page,
            per_page: per_page,
            total_pages: (filtered_count.to_f / per_page).ceil,
            stats: {
              total: total_count,
              active: active_count,
              by_trade_type: trade_type_counts
            }
          }
        }
      end

      # GET /api/v1/contractors/:id
      def show
        return unless authorize_action!('contractors', 'read')

        render json: contractor_json(@contractor)
      end

      # POST /api/v1/contractors
      def create
        return unless authorize_action!('contractors', 'create')

        @contractor = @company.contractors.build(contractor_params)

        if @contractor.save
          render json: contractor_json(@contractor), status: :created
        else
          render json: { errors: @contractor.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/contractors/:id
      def update
        return unless authorize_action!('contractors', 'update')

        update_attrs = contractor_params.to_h

        # Handle custom_field_values MERGE (not replace)
        # Documents are stored as arrays of hashes in custom_field_values JSONB
        # e.g. { license_documents: [{ url:, s3_key:, filename:, size:, content_type: }] }
        if params.dig(:contractor, :custom_field_values).present?
          existing = @contractor.custom_field_values || {}
          incoming = params[:contractor][:custom_field_values].to_unsafe_h
          update_attrs['custom_field_values'] = existing.merge(incoming)
        end

        if @contractor.update(update_attrs)
          render json: contractor_json(@contractor)
        else
          render json: { errors: @contractor.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/contractors/:id/sms-consent
      # Body: { opted_in: true|false, note: "how consent was obtained" }
      #
      # Deliberately a separate endpoint rather than a permitted attribute on
      # update. sms_opt_in is a TCPA consent flag, and routing it through here
      # guarantees every grant carries a source, a timestamp, and the user who
      # attested to it. A bare permit would let it be flipped with no record.
      def sms_consent
        return unless authorize_action!('contractors', 'update')

        opted_in = ActiveModel::Type::Boolean.new.cast(params[:opted_in])

        if opted_in && @contractor.phone.blank?
          return render json: { error: 'Add a phone number before recording SMS consent' },
                        status: :unprocessable_entity
        end

        if opted_in && params[:note].blank?
          return render json: { error: 'Describe how the contractor gave consent' },
                        status: :unprocessable_entity
        end

        @contractor.record_sms_consent!(
          opted_in: opted_in,
          source: opted_in ? 'dealer_recorded' : nil,
          user: current_user,
          note: params[:note]
        )

        render json: contractor_json(@contractor.reload)
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/contractors/:id (soft delete)
      def destroy
        return unless authorize_action!('contractors', 'delete')

        @contractor.update!(is_deleted: true)
        head :no_content
      end

      # GET /api/v1/contractors/vendors
      def vendors
        return unless authorize_action!('contractors', 'read')

        vendors = @company.contractors.not_deleted.active.vendors

        if params[:search].present?
          search_term = "%#{params[:search]}%"
          vendors = vendors.where("name ILIKE ? OR trade_type ILIKE ?", search_term, search_term)
        end

        render json: vendors.limit(50).map { |v|
          { id: v.id, name: v.name, tradeType: v.trade_type }
        }
      end

      # GET /api/v1/contractors/stats
      def stats
        return unless authorize_action!('contractors', 'read')

        contractors = @company.contractors.not_deleted

        render json: {
          by_status: contractors.group(:status).count,
          by_trade_type: contractors.group(:trade_type).count,
          total: contractors.count,
          active: contractors.active.count
        }
      end

      private

      def set_contractor
        @contractor = @company.contractors.not_deleted.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Contractor not found' }, status: :not_found
      end

      def contractor_params
        params.require(:contractor).permit(
          :name, :contact_name, :email, :phone, :trade_type,
          :license_number, :license_state, :license_expiry,
          :insurance_provider, :insurance_policy_number, :insurance_expiry,
          :bonded, :bond_amount, :bond_expiry,
          :hourly_rate, :notes, :status, :rating, :is_vendor
        )
        # NOTE: custom_field_values handled separately in update action
        # to support deep merge of document arrays
      end

      def contractor_json(contractor)
        {
          id: contractor.id,
          companyId: contractor.company_id,
          name: contractor.name,
          contactName: contractor.contact_name,
          email: contractor.email,
          phone: contractor.phone,
          tradeType: contractor.trade_type,
          licenseNumber: contractor.license_number,
          licenseState: contractor.license_state,
          licenseExpiry: contractor.license_expiry,
          insuranceProvider: contractor.insurance_provider,
          insurancePolicyNumber: contractor.insurance_policy_number,
          insuranceExpiry: contractor.insurance_expiry,
          bonded: contractor.bonded,
          bondAmount: contractor.bond_amount,
          bondExpiry: contractor.bond_expiry,
          hourlyRate: contractor.hourly_rate,
          notes: contractor.notes,
          status: contractor.status,
          rating: contractor.rating,
          isVendor: contractor.is_vendor,
          customFieldValues: contractor.custom_field_values,
          smsConsent: contractor.sms_consent_json,
          createdAt: contractor.created_at,
          updatedAt: contractor.updated_at
        }
      end
    end
  end
end
