# frozen_string_literal: true

module Api
  module V1
    # Issues (complaints) nested under a service ticket. Each issue owns its
    # parts, labor and pay type; the ticket's flat arrays are kept in sync as a
    # derived mirror by ServiceTicketIssue#sync_ticket_line_items!.
    class ServiceTicketIssuesController < ApplicationController
      before_action :set_company
      before_action :set_service_ticket
      before_action :set_issue, only: %i[show update destroy request_authorization record_authorization]

      # GET /api/v1/service-tickets/:service_ticket_id/issues
      def index
        return unless authorize_action!('service', 'read')

        render json: {
          issues: @service_ticket.issues.map { |issue| serialize_issue(issue) },
          policy: policy.to_h
        }
      end

      # GET .../issues/:id
      def show
        return unless authorize_action!('service', 'read')

        render json: { issue: serialize_issue(@issue) }
      end

      # POST .../issues
      def create
        return unless authorize_action!('service', 'create')

        issue = @service_ticket.issues.new(issue_params)
        issue.company_id = @company.id

        return unless enforce_amount_permission!(issue)

        if issue.save
          render json: { issue: serialize_issue(issue) }, status: :created
        else
          render json: { errors: issue.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH .../issues/:id
      def update
        return unless authorize_action!('service', 'update')

        @issue.assign_attributes(issue_params)

        return unless enforce_amount_permission!(@issue)
        return unless enforce_pricing_gate!(@issue)

        if @issue.save
          render json: { issue: serialize_issue(@issue) }
        else
          render json: { errors: @issue.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE .../issues/:id
      def destroy
        return unless authorize_action!('service', 'delete')

        @issue.soft_delete!
        render json: { success: true }
      end

      # POST .../issues/reorder
      def reorder
        return unless authorize_action!('service', 'update')

        ids = params[:ordered_ids] || params[:ids] || []
        ids.each_with_index do |id, index|
          @service_ticket.issues.where(id: id).update_all(position: index)
        end

        render json: { issues: @service_ticket.issues.reload.map { |i| serialize_issue(i) } }
      end

      # POST .../issues/:id/request-authorization
      #
      # RV/Auto: ask the manufacturer to authorize the repair before it is
      # performed. The OEM's answer arrives via record_authorization.
      def request_authorization
        return unless authorize_action!('service', 'update')

        unless @issue.pay_type == 'warranty'
          return render json: { error: 'Only warranty issues require authorization' },
                        status: :unprocessable_entity
        end

        @issue.update!(
          authorization_status: 'requested',
          requested_hours: params[:requested_hours].presence || @issue.requested_hours,
          authorization_requested_at: Time.current,
          authorization_notes: params[:notes].presence || @issue.authorization_notes
        )

        render json: { issue: serialize_issue(@issue) }
      end

      # POST .../issues/:id/record-authorization
      def record_authorization
        return unless authorize_action!('service', 'update')

        status = params[:authorization_status].to_s
        unless ServiceTicketIssue::AUTHORIZATION_STATUSES.include?(status)
          return render json: { error: "Invalid authorization status: #{status}" },
                        status: :unprocessable_entity
        end

        @issue.update!(
          authorization_status: status,
          authorization_number: params[:authorization_number].presence || @issue.authorization_number,
          approved_hours: params[:approved_hours].presence || @issue.approved_hours,
          approved_amount: params[:approved_amount].presence || @issue.approved_amount,
          authorization_responded_at: Time.current,
          authorization_notes: params[:notes].presence || @issue.authorization_notes
        )

        render json: { issue: serialize_issue(@issue) }
      end

      private

      def set_company
        return render json: { error: 'Authentication required' }, status: :unauthorized unless current_user

        @company = current_company
        render json: { error: 'Company not found' }, status: :not_found if @company.nil?
      end

      def set_service_ticket
        @service_ticket = @company.service_tickets.find_by(id: params[:service_ticket_id])
        render json: { error: 'Service ticket not found' }, status: :not_found if @service_ticket.nil?
      end

      def set_issue
        @issue = @service_ticket.all_issues.find_by(id: params[:id])
        render json: { error: 'Issue not found' }, status: :not_found if @issue.nil?
      end

      def policy
        @policy ||= ServiceWarrantyPolicy.for_company(@company)
      end

      def actor_kind
        ServiceWarrantyPolicy.actor_kind_for(current_user)
      end

      # Blocks amount writes from actors the company's policy does not let set
      # money. Under the strict RV/Auto defaults this keeps pricing with the
      # warranty administrator; MH leaves it open.
      def enforce_amount_permission!(issue)
        return true unless amounts_touched?
        return true if policy.amount_setter?(actor_kind)

        render json: {
          error: 'Your role is not permitted to set dollar amounts on service issues.',
          policy: { amountSetterRoles: policy['amount_setter_roles'] }
        }, status: :forbidden
        false
      end

      # Marking an issue final is what unlocks invoicing and claim submission,
      # so the stricter policies require the 3 C's to be filled in first --
      # thin documentation is what OEM audits charge back against.
      def enforce_pricing_gate!(issue)
        return true unless issue.pricing_status == 'final'
        return true unless policy.cause_and_correction_required?
        return true if issue.cause.present? && issue.correction.present?

        render json: {
          error: 'Cause and correction are required before an issue can be marked final.'
        }, status: :unprocessable_entity
        false
      end

      def amounts_touched?
        return false unless params[:issue].is_a?(ActionController::Parameters)

        params[:issue].key?(:parts) ||
          params[:issue].key?(:labor) ||
          params[:issue].key?(:vendor_invoice_amount) ||
          params[:issue].key?(:approved_amount)
      end

      def issue_params
        params.require(:issue).permit(
          :title, :complaint, :cause, :correction,
          :status, :pay_type, :manufacturer_id,
          :visibility, :portal_visible, :position,
          :pricing_status,
          :authorization_number, :authorization_status,
          :requested_hours, :approved_hours, :approved_amount,
          :authorization_notes, :labor_op_code,
          :vendor_invoice_number, :vendor_invoice_amount, :vendor_invoice_received_at,
          parts: %i[id partNumber description partId estQuantity estUnitCost
                    actQuantity actUnitCost addedBy confirmedAt],
          labor: %i[id description estHours estRate actHours actRate addedBy confirmedAt],
          custom_field_values: {}
        )
      end

      def serialize_issue(issue)
        issue.as_api_json
      end

    end
  end
end
