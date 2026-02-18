# frozen_string_literal: true

module Api
  module Partner
    module V1
      class LoansController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :loan

        before_action :authorize_loans
        before_action :set_loan, only: [:show, :update, :destroy]

        # GET /api/partner/v1/loans
        def index
          loans = company_scope(Loan).where(is_deleted: false)

          # Filters
          loans = loans.where(status: params[:status]) if params[:status].present?
          loans = loans.where(loan_type: params[:loan_type]) if params[:loan_type].present?
          loans = loans.where(location_id: params[:location_id]) if params[:location_id].present?
          loans = loans.where(borrower_type: params[:borrower_type], borrower_id: params[:borrower_id]) if params[:borrower_type].present? && params[:borrower_id].present?
          loans = loans.where(auto_pay_enabled: params[:auto_pay] == "true") if params[:auto_pay].present?
          loans = loans.where("days_past_due > 0") if params[:past_due] == "true"

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            loans = loans.where("loan_number ILIKE :q OR external_loan_id ILIKE :q", q: q)
          end

          # Cursor-based pagination
          loans = loans.order(:id)
          loans = loans.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          loans = loans.limit(limit + 1)

          records = loans.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |l| loan_json(l) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/loans/:id
        def show
          render json: { data: loan_json(@loan, detailed: true) }
        end

        # POST /api/partner/v1/loans
        def create
          loan = company_scope(Loan).new(loan_params)

          if loan.save
            render json: { data: loan_json(loan, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: loan.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/loans/:id
        def update
          if @loan.update(loan_params)
            render json: { data: loan_json(@loan, detailed: true) }
          else
            render json: { error: "Validation failed", details: @loan.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/loans/:id
        def destroy
          @loan.update!(is_deleted: true, deleted_at: Time.current)
          render json: { data: { id: @loan.id, deleted: true } }
        end

        private

        def authorize_loans
          case action_name
          when "index", "show"
            authorize_permission!(:loans, :read)
          when "create"
            authorize_permission!(:loans, :create)
          when "update"
            authorize_permission!(:loans, :update)
          when "destroy"
            authorize_permission!(:loans, :delete)
          end
        end

        def set_loan
          @loan = company_scope(Loan).where(is_deleted: false).find(params[:id])
        end

        def loan_params
          params.permit(
            :loan_type, :status, :location_id,
            :borrower_type, :borrower_id,
            :financed_entity_type, :financed_entity_id,
            :principal_amount, :interest_rate, :term_months,
            :origination_date, :first_payment_date, :maturity_date,
            :payment_frequency, :regular_payment_amount, :day_of_month_due,
            :auto_pay_enabled, :default_payment_method_id,
            :external_loan_id, :notes, :origination_fee
          )
        end

        def loan_json(loan, detailed: false)
          json = {
            id: loan.id,
            loan_number: loan.loan_number,
            loan_type: loan.loan_type,
            status: loan.status,
            principal_amount: loan.principal_amount,
            current_balance: loan.current_balance,
            interest_rate: loan.interest_rate,
            borrower_type: loan.borrower_type,
            borrower_id: loan.borrower_id,
            location_id: loan.location_id,
            next_payment_date: loan.next_payment_date&.iso8601,
            days_past_due: loan.days_past_due,
            created_at: loan.created_at&.iso8601,
            updated_at: loan.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              term_months: loan.term_months,
              payment_frequency: loan.payment_frequency,
              regular_payment_amount: loan.regular_payment_amount,
              day_of_month_due: loan.day_of_month_due,
              origination_date: loan.origination_date&.iso8601,
              first_payment_date: loan.first_payment_date&.iso8601,
              maturity_date: loan.maturity_date&.iso8601,
              last_payment_date: loan.last_payment_date&.iso8601,
              total_paid: loan.total_paid,
              total_interest_paid: loan.total_interest_paid,
              payments_made: loan.payments_made,
              payments_remaining: loan.payments_remaining,
              late_fees_assessed: loan.late_fees_assessed,
              origination_fee: loan.origination_fee,
              auto_pay_enabled: loan.auto_pay_enabled,
              default_payment_method_id: loan.default_payment_method_id,
              financed_entity_type: loan.financed_entity_type,
              financed_entity_id: loan.financed_entity_id,
              external_loan_id: loan.external_loan_id,
              notes: loan.notes
            )
          end

          json
        end
      end
    end
  end
end
