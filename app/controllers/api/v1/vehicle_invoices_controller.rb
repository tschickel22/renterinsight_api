# frozen_string_literal: true

module Api
  module V1
    # Nested singular resource under /api/v1/vehicles/:vehicle_id/invoice.
    # Internal-only manufacturer-invoice capture (Max Advance Phase 1). One invoice
    # per vehicle — create and update both UPSERT the single record.
    #
    # Access is gated to inventory:update OR accounting:update (admin / finance /
    # inventory managers) — cost-basis data, so even reads require an internal role.
    # company_id is NEVER permitted; the vehicle is derived from the route and the
    # company from scope.
    class VehicleInvoicesController < ApplicationController
      before_action :set_company
      before_action :set_vehicle

      # GET /api/v1/vehicles/:vehicle_id/invoice
      def show
        return unless authorize_invoice_access!

        invoice = @vehicle.invoice
        return render(json: { error: 'No invoice on file' }, status: :not_found) unless invoice

        render json: invoice_json(invoice)
      end

      # POST /api/v1/vehicles/:vehicle_id/invoice  (upsert)
      def create
        upsert
      end

      # PATCH/PUT /api/v1/vehicles/:vehicle_id/invoice  (upsert)
      def update
        upsert
      end

      private

      # Single code path for create + update: there is at most one invoice per vehicle,
      # so we find-or-build and assign. company_id is forced from scope (immutable),
      # vehicle from the route — never from the request body.
      def upsert
        return unless authorize_invoice_access!

        invoice = @vehicle.invoice || @vehicle.build_invoice
        existing = invoice.persisted?
        invoice.assign_attributes(invoice_params)
        invoice.company = @company

        if invoice.save
          render json: invoice_json(invoice), status: existing ? :ok : :created
        else
          render json: { errors: invoice.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def set_company
        company_id = current_company_id
        unless company_id.present?
          render json: { error: 'No company context' }, status: :forbidden
          return
        end

        @company = ::Company.find_by(id: company_id)
        render(json: { error: 'Company not found' }, status: :not_found) and return unless @company
      end

      def set_vehicle
        @vehicle = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            @company.vehicles.active.where('location_id IN (?) OR location_id IS NULL', location_ids).find(params[:vehicle_id])
          else
            @company.vehicles.active.find(params[:vehicle_id])
          end
        else
          @company.vehicles.active.find(params[:vehicle_id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Vehicle not found or access denied' }, status: :not_found
      end

      # Gate: inventory:update OR accounting:update. Returns false (and renders 403)
      # when neither is held, so callers do `return unless authorize_invoice_access!`.
      def authorize_invoice_access!
        return true if can?('inventory', 'update') || can?('accounting', 'update')

        render json: {
          error: 'Forbidden - Insufficient permissions',
          required_permission: 'inventory:update or accounting:update'
        }, status: :forbidden
        false
      end

      def invoice_params
        params.require(:invoice).permit(
          :gross_invoice, :base_price, :options_total, :material_surcharge, :factory_freight,
          :sales_allowance, :hud_fees, :state_assoc_fees, :tax_from_invoice, :total_invoice,
          :nada_base, :vep_code, :wind_zone,
          :invoice_number, :invoice_date, :manufacturer, :scanned_document_id
          # company_id and vehicle_id intentionally excluded (derived from scope/route).
        )
      end

      def invoice_json(inv)
        {
          id: inv.id,
          vehicleId: inv.vehicle_id,
          grossInvoice: inv.gross_invoice,
          basePrice: inv.base_price,
          optionsTotal: inv.options_total,
          materialSurcharge: inv.material_surcharge,
          factoryFreight: inv.factory_freight,
          salesAllowance: inv.sales_allowance,
          hudFees: inv.hud_fees,
          stateAssocFees: inv.state_assoc_fees,
          taxFromInvoice: inv.tax_from_invoice,
          totalInvoice: inv.total_invoice,
          nadaBase: inv.nada_base,
          vepCode: inv.vep_code,
          windZone: inv.wind_zone,
          invoiceNumber: inv.invoice_number,
          invoiceDate: inv.invoice_date,
          manufacturer: inv.manufacturer,
          scannedDocumentId: inv.scanned_document_id,
          createdAt: inv.created_at,
          updatedAt: inv.updated_at
        }
      end
    end
  end
end
