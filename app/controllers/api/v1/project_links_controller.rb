# frozen_string_literal: true

module Api
  module V1
    # Handing a project or phase to a linked installer (dealer side), and
    # answering and billing it (installer side). E68 steps 5c and 5e.
    class ProjectLinksController < ApplicationController
      before_action :set_company_scope
      before_action :set_project, only: %i[index create]
      before_action :set_dealer_link, only: %i[cancel]
      before_action :set_installer_link, only: %i[accept decline bill]

      # GET /api/v1/projects/:project_id/project_links
      # The project's hand-offs, and the linked installers it could go to.
      def index
        return unless authorize_action!('deals', 'read')

        links = ProjectLink.where(dealer_company_id: @company.id, dealer_project_id: @project.id)
                           .includes(:installer_company, :dealer_phase, :link_phases).order(created_at: :desc)
        installers = CompanyLink.active.where(dealer_company_id: @company.id).includes(:installer_company, :dealer_vendor)
        render json: {
          project_links: links.map { |pl| dealer_json(pl) },
          installers: installers.map { |l| { company_link_id: l.id, name: l.installer_company.name, vendor_id: l.dealer_vendor_id, vendor_name: l.dealer_vendor.name } }
        }
      end

      # POST /api/v1/projects/:project_id/project_links { company_link_id, project_phase_id, fee, note }
      def create
        return unless authorize_action!('deals', 'update')

        link = CompanyLink.active.find_by(id: params[:company_link_id], dealer_company_id: @company.id)
        phase = params[:project_phase_id].present? ? @project.project_phases.find_by(id: params[:project_phase_id]) : nil
        if params[:project_phase_id].present? && phase.nil?
          return render json: { error: 'Phase not found' }, status: :not_found
        end

        pl = service.offer!(project: @project, phase: phase, link: link, fee: params[:fee], note: params[:note])
        render json: { project_link: dealer_json(pl) }, status: :created
      rescue ProjectLinkService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/project_links/:id/cancel
      def cancel
        return unless authorize_action!('deals', 'update')

        render json: { project_link: dealer_json(service.cancel!(@pl)) }
      rescue ProjectLinkService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/project_links/:id/accept
      def accept
        return unless authorize_action!('deals', 'update')

        pl = service.accept!(@pl)
        render json: { project_link: { id: pl.id, status: pl.status, installer_project_id: pl.installer_project_id } }
      rescue ProjectLinkService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/project_links/:id/decline { reason }
      def decline
        return unless authorize_action!('deals', 'update')

        pl = service.decline!(@pl, reason: params[:reason])
        render json: { project_link: { id: pl.id, status: pl.status } }
      rescue ProjectLinkService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/project_links/:id/bill { amount, invoice_number, notes }
      def bill
        return unless authorize_action!('deals', 'update')

        pl = service.bill_dealer!(@pl, amount: params[:amount], invoice_number: params[:invoice_number], notes: params[:notes])
        render json: { project_link: { id: pl.id, status: pl.status, installer_invoice_id: pl.installer_invoice_id,
                                       installer_invoice_number: pl.installer_invoice&.invoice_number } }
      rescue ProjectLinkService::Error, ContractorInvoiceService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def service
        @service ||= ProjectLinkService.new(@company, actor: current_user)
      end

      def set_project
        @project = @company.projects.where(is_deleted: [false, nil]).find_by(id: params[:project_id])
        render json: { error: 'Project not found' }, status: :not_found unless @project
      end

      def set_dealer_link
        @pl = ProjectLink.find_by(id: params[:id], dealer_company_id: @company.id)
        render json: { error: 'Not found' }, status: :not_found unless @pl
      end

      def set_installer_link
        @pl = ProjectLink.find_by(id: params[:id], installer_company_id: @company.id)
        render json: { error: 'Not found' }, status: :not_found unless @pl
      end

      # What the dealer sees: the installer, the fee, where it stands. The
      # installer's own tasks, subcontractors and costs stay with them.
      def dealer_json(pl)
        {
          id: pl.id, status: pl.status, installer_name: pl.installer_company.name,
          project_phase_id: pl.dealer_phase_id, scope_label: pl.scope_label,
          phase_ids: pl.dealer_phase ? [pl.dealer_phase_id] : pl.dealer_project.project_phases.pluck(:id),
          fee_amount: pl.fee_amount&.to_f, note: pl.note, decline_reason: pl.decline_reason,
          offered_at: pl.offered_at, responded_at: pl.responded_at,
          dealer_bill_id: pl.dealer_bill_id, can_cancel: pl.status.in?(%w[offered accepted]) && pl.dealer_bill_id.nil?
        }
      end
    end
  end
end
