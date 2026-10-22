# frozen_string_literal: true

module Api
  module V1
    # Handing a project or phase to a linked installer (dealer side), and
    # answering and billing it (installer side). E68 steps 5c and 5e.
    class ProjectLinksController < ApplicationController
      include LinkPricingJson

      before_action :set_company_scope
      before_action :set_project, only: %i[index create]
      before_action :set_dealer_link, only: %i[cancel]
      before_action :set_installer_link, only: %i[accept decline bill request_change]

      # GET /api/v1/projects/:project_id/project_links
      # The project's hand-offs, and the linked installers it could go to.
      def index
        return unless authorize_action!('deals', 'read')

        links = ProjectLink.where(dealer_company_id: @company.id, dealer_project_id: @project.id)
                           .includes(:installer_company, :dealer_phase, :link_phases).order(created_at: :desc)
        installers = CompanyLink.active.where(dealer_company_id: @company.id).includes(:installer_company, :dealer_vendor)
        render json: {
          project_links: links.map { |pl| dealer_json(pl) },
          installers: installers.map do |l|
            { company_link_id: l.id, name: l.installer_company.name, vendor_id: l.dealer_vendor_id, vendor_name: l.dealer_vendor.name,
              rate_card: rate_card_json(l.current_rate_card) }
          end
        }
      end

      # POST /api/v1/projects/:project_id/project_links
      #   { company_link_id, project_phase_ids (or project_phase_id), note,
      #     price_mode: card | dealer | quote, card_lines: [{ item_key, qty }], fee }
      # No phases sends the whole project.
      def create
        return unless authorize_action!('deals', 'update')

        link = CompanyLink.active.find_by(id: params[:company_link_id], dealer_company_id: @company.id)
        ids = Array(params[:project_phase_ids]).compact_blank.presence || Array(params[:project_phase_id]).compact_blank
        ids = ids.map(&:to_i).uniq
        phases = @project.project_phases.where(id: ids).to_a
        return render json: { error: 'Phase not found' }, status: :not_found if phases.size != ids.size

        card_lines = (params.permit(card_lines: %i[item_key qty])[:card_lines] || []).map(&:to_h)
        pl = service.offer!(project: @project, phases: phases, link: link, fee: params[:fee], note: params[:note],
                            price_mode: params[:price_mode], card_lines: card_lines)
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

      # POST /api/v1/project_links/:id/accept { price_lines: [{ item_key, qty } | { name, qty, price }], price_note }
      # Price lines are required on a job sent for a quote, and on a priced
      # job ask for a different price. Either way the dealer approves it.
      def accept
        return unless authorize_action!('deals', 'update')

        pl = service.accept!(@pl, price_lines: price_lines_param, price_note: params[:price_note])
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

      # POST /api/v1/project_links/:id/changes
      #   { kind: change | price, description, dealer_phase_id, lines: [...] }
      def request_change
        return unless authorize_action!('deals', 'update')

        change = service.request_change!(@pl, kind: params[:kind].presence || 'change', lines: price_lines_param(:lines),
                                              description: params[:description], dealer_phase_id: params[:dealer_phase_id])
        render json: { change: link_change_json(change) }, status: :created
      rescue ProjectLinkService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def price_lines_param(key = :price_lines)
        (params.permit(key => %i[item_key name qty price])[key] || []).map(&:to_h)
      end

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
          phase_ids: pl.dealer_phases.map(&:id), whole_project: pl.whole_project?,
          fee_amount: pl.fee_amount&.to_f, note: pl.note, decline_reason: pl.decline_reason,
          offered_at: pl.offered_at, responded_at: pl.responded_at,
          dealer_bill_id: pl.dealer_bill_id, can_cancel: pl.status.in?(%w[offered accepted]) && pl.dealer_bill_id.nil?
        }.merge(link_price_json(pl))
      end
    end
  end
end
