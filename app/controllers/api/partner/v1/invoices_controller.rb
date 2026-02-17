# frozen_string_literal: true

module Api
  module Partner
    module V1
      class InvoicesController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :invoice

        before_action :authorize_invoices
        before_action :set_invoice, only: [:show, :update, :destroy]

        # GET /api/partner/v1/invoices
        def index
          invoices = company_scope(Invoice).where(is_deleted: [false, nil])

          # Filters
          invoices = invoices.where(status: params[:status]) if params[:status].present?
          invoices = invoices.where(contact_id: params[:contact_id]) if params[:contact_id].present?
          invoices = invoices.where(deal_id: params[:deal_id]) if params[:deal_id].present?
          invoices = invoices.where(location_id: params[:location_id]) if params[:location_id].present?
          invoices = invoices.where(billing_category: params[:billing_category]) if params[:billing_category].present?
          invoices = invoices.where(loan_id: params[:loan_id]) if params[:loan_id].present?

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            invoices = invoices.where("invoice_number ILIKE :q OR notes ILIKE :q", q: q)
          end

          # Cursor-based pagination
          invoices = invoices.order(:id)
          invoices = invoices.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          invoices = invoices.limit(limit + 1)

          records = invoices.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |i| invoice_json(i) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/invoices/:id
        def show
          render json: { data: invoice_json(@invoice, detailed: true) }
        end

        # POST /api/partner/v1/invoices
        def create
          invoice = company_scope(Invoice).new(invoice_params)

          if invoice.save
            render json: { data: invoice_json(invoice, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: invoice.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/invoices/:id
        def update
          if @invoice.update(invoice_params)
            render json: { data: invoice_json(@invoice, detailed: true) }
          else
            render json: { error: "Validation failed", details: @invoice.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/invoices/:id
        def destroy
          @invoice.update!(is_deleted: true)
          render json: { data: { id: @invoice.id, deleted: true } }
        end

        private

        def authorize_invoices
          case action_name
          when "index", "show"
            authorize_permission!(:invoices, :read)
          when "create"
            authorize_permission!(:invoices, :create)
          when "update"
            authorize_permission!(:invoices, :update)
          when "destroy"
            authorize_permission!(:invoices, :delete)
          end
        end

        def set_invoice
          @invoice = company_scope(Invoice).where(is_deleted: [false, nil]).find(params[:id])
        end

        def invoice_params
          params.permit(
            :contact_id, :deal_id, :location_id, :loan_id, :quote_id, :sales_rep_id,
            :invoice_date, :due_date, :status, :billing_category,
            :tax_rate, :notes, :terms, :footer_text,
            invoice_items_attributes: [:id, :description, :quantity, :unit_price, :amount, :_destroy]
          )
        end

        def invoice_json(invoice, detailed: false)
          json = {
            id: invoice.id,
            invoice_number: invoice.invoice_number,
            status: invoice.status,
            invoice_date: invoice.invoice_date&.iso8601,
            due_date: invoice.due_date&.iso8601,
            subtotal: invoice.subtotal,
            tax_amount: invoice.tax_amount,
            total: invoice.total,
            amount_paid: invoice.amount_paid,
            amount_due: invoice.amount_due,
            contact_id: invoice.contact_id,
            deal_id: invoice.deal_id,
            location_id: invoice.location_id,
            billing_category: invoice.billing_category,
            created_at: invoice.created_at&.iso8601,
            updated_at: invoice.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              tax_rate: invoice.tax_rate,
              notes: invoice.notes,
              terms: invoice.terms,
              footer_text: invoice.footer_text,
              loan_id: invoice.loan_id,
              quote_id: invoice.quote_id,
              sales_rep_id: invoice.sales_rep_id,
              source_type: invoice.source_type,
              source_id: invoice.source_id,
              sent_at: invoice.sent_at&.iso8601,
              viewed_at: invoice.viewed_at&.iso8601,
              paid_at: invoice.paid_at&.iso8601,
              items: invoice.invoice_items.map { |item| invoice_item_json(item) }
            )
          end

          json
        end

        def invoice_item_json(item)
          {
            id: item.id,
            description: item.description,
            quantity: item.quantity,
            unit_price: item.unit_price,
            amount: item.amount
          }
        end
      end
    end
  end
end
