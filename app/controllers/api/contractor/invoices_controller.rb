# frozen_string_literal: true

module Api
  module Contractor
    # A contractor sends an invoice for a job from the portal (E68 step 2). It
    # becomes a draft bill for the dealer, linked to the project and the cost
    # line it pays for. See ContractorInvoiceService.
    class InvoicesController < BaseController
      before_action :set_project

      ALLOWED_TYPES = %w[application/pdf image/jpeg image/png image/heic image/heif image/webp].freeze

      # GET /api/contractor/projects/:project_id/invoices
      def index
        bills = @project.company.bills.where(project_id: @project.id, vendor_id: @vendor.id, source: 'contractor_portal', is_deleted: false)
                        .order(created_at: :desc)
        render json: { items: bills.map { |b| invoice_json(b) } }
      end

      # POST /api/contractor/projects/:project_id/invoices  (multipart)
      # file, amount, invoice_number?, invoice_date?, phase_id?, assignment_id?, notes?
      def create
        file = params[:file]
        return render(json: { error: 'Attach the invoice' }, status: :unprocessable_entity) if file.blank?
        return render(json: { error: 'File too large. Maximum size is 10MB' }, status: :unprocessable_entity) if file.size > 10.megabytes
        unless ALLOWED_TYPES.include?(file.content_type)
          return render(json: { error: 'Send a PDF or a photo of the invoice' }, status: :unprocessable_entity)
        end

        phase = params[:phase_id].present? ? @project.project_phases.find_by(id: params[:phase_id]) : nil
        return render(json: { error: 'Phase not found' }, status: :not_found) if params[:phase_id].present? && !phase

        assignment = nil
        if params[:assignment_id].present?
          assignment = ContractorAssignment.where(contractor_id: all_contractor_ids, company_id: @project.company_id)
                                           .find_by(id: params[:assignment_id])
          return render(json: { error: 'Assignment not found' }, status: :not_found) unless assignment
        end

        service = ContractorInvoiceService.new(contractor: @vendor, project: @project, phase: phase, assignment: assignment)
        bill = service.submit!(
          file: file,
          amount: params[:amount],
          invoice_number: params[:invoice_number],
          invoice_date: params[:invoice_date],
          notes: params[:notes]
        )
        render json: { invoice: invoice_json(bill) }, status: :created
      rescue ContractorInvoiceService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # The project must be one this contractor can see, and they invoice as
      # their own vendor record at that dealer.
      def set_project
        @project = Project.where(is_deleted: [false, nil]).find_by(id: params[:project_id])
        unless @project && visible_project_ids.include?(@project.id)
          return render(json: { error: 'Project not found' }, status: :not_found)
        end

        @vendor = all_contractors.find_by(company_id: @project.company_id)
        render(json: { error: 'Project not found' }, status: :not_found) unless @vendor
      end

      # What the contractor sees: their own figures and where the bill stands,
      # never the dealer's accounts or edits.
      STATUS_LABELS = { 'draft' => 'Received', 'pending' => 'Approved', 'partially_paid' => 'Partly paid',
                        'paid' => 'Paid', 'void' => 'Declined' }.freeze

      def invoice_json(bill)
        sub = bill.submission || {}
        {
          id: bill.id,
          invoice_number: bill.reference_number,
          amount: sub['amount'] || bill.total_amount.to_s,
          invoice_date: bill.bill_date,
          status: bill.status,
          status_label: STATUS_LABELS[bill.status] || bill.status,
          amount_paid: bill.amount_paid,
          phase_id: sub['phase_id'],
          submitted_at: bill.created_at,
          filename: bill.attachments&.first&.dig('filename')
        }
      end
    end
  end
end
