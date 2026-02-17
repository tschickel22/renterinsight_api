# frozen_string_literal: true

module Api
  module Partner
    module V1
      class PaymentsController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :payment

        before_action :authorize_payments
        before_action :set_payment, only: [:show, :update, :destroy]

        # GET /api/partner/v1/payments
        def index
          payments = company_scope(Payment).where(is_deleted: false)

          # Filters
          payments = payments.where(status: params[:status]) if params[:status].present?
          payments = payments.where(payment_type: params[:payment_type]) if params[:payment_type].present?
          payments = payments.where(loan_id: params[:loan_id]) if params[:loan_id].present?
          payments = payments.where(location_id: params[:location_id]) if params[:location_id].present?
          payments = payments.where(gateway_name: params[:gateway_name]) if params[:gateway_name].present?
          payments = payments.where(payer_type: params[:payer_type], payer_id: params[:payer_id]) if params[:payer_type].present? && params[:payer_id].present?
          payments = payments.where(payable_type: params[:payable_type], payable_id: params[:payable_id]) if params[:payable_type].present? && params[:payable_id].present?

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            payments = payments.where("payment_number ILIKE :q OR external_id ILIKE :q", q: q)
          end

          # Cursor-based pagination
          payments = payments.order(:id)
          payments = payments.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          payments = payments.limit(limit + 1)

          records = payments.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |p| payment_json(p) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/payments/:id
        def show
          render json: { data: payment_json(@payment, detailed: true) }
        end

        # POST /api/partner/v1/payments
        def create
          payment = company_scope(Payment).new(payment_params)

          if payment.save
            render json: { data: payment_json(payment, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: payment.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/payments/:id
        def update
          if @payment.update(payment_params)
            render json: { data: payment_json(@payment, detailed: true) }
          else
            render json: { error: "Validation failed", details: @payment.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/payments/:id
        def destroy
          @payment.update!(is_deleted: true, deleted_at: Time.current)
          render json: { data: { id: @payment.id, deleted: true } }
        end

        private

        def authorize_payments
          case action_name
          when "index", "show"
            authorize_permission!(:payments, :read)
          when "create"
            authorize_permission!(:payments, :create)
          when "update"
            authorize_permission!(:payments, :update)
          when "destroy"
            authorize_permission!(:payments, :delete)
          end
        end

        def set_payment
          @payment = company_scope(Payment).where(is_deleted: false).find(params[:id])
        end

        def payment_params
          params.permit(
            :payment_type, :status, :amount, :payment_date,
            :loan_id, :location_id, :payment_method_id,
            :payer_type, :payer_id, :payable_type, :payable_id,
            :principal_amount, :interest_amount, :fee_amount, :late_fee_amount,
            :gateway_name, :external_id, :notes,
            :scheduled_at
          )
        end

        def payment_json(payment, detailed: false)
          json = {
            id: payment.id,
            payment_number: payment.payment_number,
            payment_type: payment.payment_type,
            status: payment.status,
            amount: payment.amount,
            total_charged: payment.total_charged,
            payment_date: payment.payment_date&.iso8601,
            loan_id: payment.loan_id,
            location_id: payment.location_id,
            payer_type: payment.payer_type,
            payer_id: payment.payer_id,
            gateway_name: payment.gateway_name,
            created_at: payment.created_at&.iso8601,
            updated_at: payment.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              principal_amount: payment.principal_amount,
              interest_amount: payment.interest_amount,
              fee_amount: payment.fee_amount,
              late_fee_amount: payment.late_fee_amount,
              processing_fee: payment.processing_fee,
              fee_responsibility: payment.fee_responsibility,
              fee_type: payment.fee_type,
              fee_value: payment.fee_value,
              payment_method_id: payment.payment_method_id,
              payable_type: payment.payable_type,
              payable_id: payment.payable_id,
              external_id: payment.external_id,
              scheduled_at: payment.scheduled_at&.iso8601,
              processed_at: payment.processed_at&.iso8601,
              is_refunded: payment.is_refunded,
              refund_amount: payment.refund_amount,
              refunded_at: payment.refunded_at&.iso8601,
              refund_reason: payment.refund_reason,
              failure_reason: payment.failure_reason,
              notes: payment.notes
            )
          end

          json
        end
      end
    end
  end
end
