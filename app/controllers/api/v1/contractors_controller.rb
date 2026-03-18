# frozen_string_literal: true

module Api
  module V1
    class ContractorsController < ApplicationController
      before_action :set_company_scope
      before_action :set_contractor, only: [:show, :update, :destroy]

      # GET /api/v1/contractors
      def index
        return unless authorize_action!('contractors', 'read')

        contractors = @company.contractors.not_deleted

        # Stats counted BEFORE search (for tiles)
        total_count = contractors.count
        active_count = contractors.active.count
        trade_type_counts = contractors.group(:trade_type).count

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

      # DELETE /api/v1/contractors/:id (soft delete)
      def destroy
        return unless authorize_action!('contractors', 'delete')

        @contractor.update!(is_deleted: true)
        head :no_content
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
          :hourly_rate, :notes, :status, :rating
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
          customFieldValues: contractor.custom_field_values,
          createdAt: contractor.created_at,
          updatedAt: contractor.updated_at
        }
      end
    end
  end
end
