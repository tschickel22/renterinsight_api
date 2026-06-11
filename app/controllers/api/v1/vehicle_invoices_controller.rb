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

      # POST /api/v1/vehicles/:vehicle_id/invoice/scan  (Phase 5)
      # Vision-extract a manufacturer invoice into a DRAFT of the invoice fields. It does
      # NOT persist — the client reviews/corrects the draft, then PATCHes #update to commit.
      # Verify-before-commit is mandatory: a wrong scanned figure would skew Max Sales Price.
      def scan
        return unless authorize_invoice_access!

        source = scan_source
        return if performed? # scan_source rendered an error (doc not found / not internal)
        return render(json: { error: 'Provide a file upload or an internal document_id to scan' },
                      status: :unprocessable_entity) if source.nil?

        result = MaxAdvanceInvoiceScanService.new(@company, current_user).scan(source)

        render json: {
          draft: true,
          persisted: false,                 # nothing written to the vehicle_invoice
          requiresVerification: true,
          vehicleId: @vehicle.id,
          scannedDocumentId: @scanned_document_id, # set when scanning a stored internal doc
          fields: camelize_scan_fields(result[:fields]),
          confidence: result[:confidence],
          fieldConfidence: result[:field_confidence],
          warnings: result[:warnings],
          note: 'DRAFT only — not saved. Review/correct, then PATCH this vehicle\'s /invoice to commit.'
        }
      rescue MaxAdvanceInvoiceScanService::ScanError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # Resolve the scan source: a stored INTERNAL-ONLY vehicle document (preferred) or a
      # transient direct file upload (not stored here; persistence is the documents endpoint).
      def scan_source
        if params[:document_id].present?
          doc = @vehicle.documents.find_by(id: params[:document_id])
          unless doc
            render json: { error: 'Document not found' }, status: :not_found
            return nil
          end
          unless doc.visibility == 'internal'
            render json: { error: 'Invoice scans must use an internal-only document' }, status: :unprocessable_entity
            return nil
          end
          @scanned_document_id = doc.id
          doc.file_url
        elsif params[:file].present?
          params[:file]
        end
      end

      def camelize_scan_fields(f)
        {
          grossInvoice: f['gross_invoice'],
          basePrice: f['base_price'],
          optionsTotal: f['options_total'],
          materialSurcharge: f['material_surcharge'],
          factoryFreight: f['factory_freight'],
          salesAllowance: f['sales_allowance'],
          hudFees: f['hud_fees'],
          stateAssocFees: f['state_assoc_fees'],
          taxFromInvoice: f['tax_from_invoice'],
          acFromInvoice: f['ac_from_invoice'],
          trimOut: f['trim_out'],
          totalInvoice: f['total_invoice'],
          vepCode: f['vep_code'],
          windZone: f['wind_zone'],
          sections: f['sections'],
          manufacturer: f['manufacturer'],
          model: f['model'],
          invoiceNumber: f['invoice_number'],
          invoiceDate: f['invoice_date']
        }
      end

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
          # Seed the vehicle's Home Cost (dealer_cost) from the invoice as a starting default.
          # Done here (not only in the model after_save) so it runs on EVERY successful save —
          # ActiveRecord skips after_save on a no-op (unchanged) save, so a model callback alone
          # misses re-saves and is fragile across reloads. Idempotent + override-safe: only seeds
          # when no Cost Details have been entered. See VehicleInvoice#seed_dealer_cost_basis.
          seed_home_cost_from_invoice(invoice)
          render json: invoice_json(invoice), status: existing ? :ok : :created
        else
          render json: { errors: invoice.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # Seed dealer_cost (Home Cost) from the invoice's gross (fallback total) when the
      # vehicle has NO cost entered yet. Reloads the vehicle so the guard reads true
      # persisted values, never a stale in-memory copy. update_column avoids recursing
      # through vehicle callbacks.
      def seed_home_cost_from_invoice(invoice)
        v = @vehicle.reload
        return if v.dealer_cost.to_f.positive? || v.freight_cost.to_f.positive? ||
                  v.pdi_cost.to_f.positive? || v.total_cost.to_f.positive?

        basis = invoice.gross_invoice.to_f.positive? ? invoice.gross_invoice.to_f
                                                     : invoice.total_invoice.to_f
        return unless basis.positive?

        v.update_column(:dealer_cost, basis.round(2))
        Rails.logger.info(
          "[VehicleInvoices#seed_home_cost] vehicle ##{v.id}: seeded dealer_cost=#{basis.round(2)} from invoice ##{invoice.id}"
        )
      rescue => e
        # Never fail the invoice save because the cost seed hit a snag.
        Rails.logger.error("[VehicleInvoices#seed_home_cost] vehicle ##{@vehicle&.id}: #{e.message}")
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
          :sales_allowance, :hud_fees, :state_assoc_fees, :tax_from_invoice, :ac_from_invoice,
          :total_invoice, :nada_base, :trim_out, :vep_code, :wind_zone,
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
          acFromInvoice: inv.ac_from_invoice,
          totalInvoice: inv.total_invoice,
          nadaBase: inv.nada_base,
          trimOut: inv.trim_out,
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
