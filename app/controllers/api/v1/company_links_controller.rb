# frozen_string_literal: true

module Api
  module V1
    # Links between a dealer and an installer company, and the jobs handed
    # across them (E68 step 5). One page serves both sides: what this company
    # sent as a dealer, what it was invited to and runs as an installer.
    class CompanyLinksController < ApplicationController
      before_action :set_company_scope
      before_action :set_link, only: %i[accept end_link events]

      # GET /api/v1/company_links
      def index
        return unless authorize_action!('deals', 'read')

        as_dealer = CompanyLink.where(dealer_company_id: @company.id).where.not(status: 'ended').or(
          CompanyLink.where(dealer_company_id: @company.id, ended_at: 90.days.ago..)
        ).includes(:dealer_vendor, :installer_company).order(created_at: :desc)
        as_installer = CompanyLink.where(installer_company_id: @company.id).includes(:dealer_company, :dealer_vendor).order(created_at: :desc)
        invitations = service.invitations_for_me.includes(:dealer_company, :dealer_vendor)
        jobs = ProjectLink.where(installer_company_id: @company.id).where.not(status: 'cancelled').or(
          ProjectLink.where(installer_company_id: @company.id, status: 'cancelled', updated_at: 30.days.ago..)
        ).includes(:dealer_company, :dealer_project, :dealer_phase, :installer_project).order(offered_at: :desc).limit(200)

        render json: {
          is_admin: current_user.effective_admin?,
          agreement_version: CompanyLink::AGREEMENT_VERSION,
          as_dealer: as_dealer.map { |l| link_json(l) },
          as_installer: as_installer.map { |l| link_json(l) },
          invitations: invitations.map { |l| link_json(l) },
          jobs: jobs.map { |pl| job_json(pl) }
        }
      end

      # POST /api/v1/company_links { vendor_id, email }
      def create
        return unless authorize_action!('vendors', 'update')

        vendor = @company.vendors.find_by(id: params[:vendor_id])
        link = service.invite!(vendor: vendor, email: params[:email])
        render json: { company_link: link_json(link) }, status: :created
      rescue CompanyLinkService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/company_links/:id/accept { agree: true }
      def accept
        return render(json: { error: 'Agree to share job details to accept' }, status: :unprocessable_entity) unless ActiveModel::Type::Boolean.new.cast(params[:agree])

        link = service.accept!(@link)
        render json: { company_link: link_json(link) }
      rescue CompanyLinkService::Error, ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/company_links/:id/end
      def end_link
        side = @link.side_for(@company)
        if side == :dealer
          return unless authorize_action!('vendors', 'update')
        elsif !current_user.effective_admin?
          return render json: { error: 'Only an admin can end a link' }, status: :forbidden
        end

        link = service.end!(@link, reason: params[:reason])
        render json: { company_link: link_json(link) }
      rescue CompanyLinkService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/company_links/:id/events
      def events
        return unless authorize_action!('deals', 'read')

        rows = @link.events.includes(:user, :project_link).order(created_at: :desc).limit(200)
        render json: {
          events: rows.map do |e|
            { id: e.id, kind: e.kind, summary: e.summary, at: e.created_at,
              by_company: e.company_id == @link.dealer_company_id ? @link.dealer_company.name : @link.installer_company&.name,
              by_user: e.company_id == @company.id ? e.user&.name : nil }
          end
        }
      end

      private

      def service
        @service ||= CompanyLinkService.new(@company, actor: current_user)
      end

      # A link this company is on, or an invitation addressed to this admin.
      def set_link
        @link = CompanyLink.where(dealer_company_id: @company.id).or(CompanyLink.where(installer_company_id: @company.id))
                           .find_by(id: params[:id]) ||
                service.invitations_for_me.find_by(id: params[:id])
        render json: { error: 'Not found' }, status: :not_found unless @link
      end

      def link_json(l)
        dealer_side = l.dealer_company_id == @company.id
        {
          id: l.id, status: l.status, side: dealer_side ? 'dealer' : 'installer',
          dealer_company_name: l.dealer_company.name,
          installer_company_name: l.installer_company&.name,
          vendor_id: dealer_side ? l.dealer_vendor_id : nil,
          vendor_name: l.dealer_vendor.name,
          invite_email: dealer_side || l.invited? ? l.invite_email : nil,
          invited_at: l.created_at, accepted_at: l.accepted_at, ended_at: l.ended_at
        }
      end

      # What the installer sees. Before acceptance: the work, the customer and
      # site, the dates, the fee and note. Never the deal's price or the
      # dealer's costs.
      def job_json(pl)
        dp = pl.dealer_project
        {
          id: pl.id, status: pl.status, dealer_company_name: pl.dealer_company.name,
          scope_label: pl.scope_label, fee_amount: pl.fee_amount&.to_f, note: pl.note,
          offered_at: pl.offered_at, responded_at: pl.responded_at, decline_reason: pl.decline_reason,
          customer_name: dp.customer_display_name, customer_email: dp.customer_email, customer_phone: dp.customer_phone,
          site: [dp.delivery_street, dp.delivery_city, dp.delivery_state, dp.delivery_zip].compact_blank.join(', '),
          home: [dp.home_make, dp.home_model].compact_blank.join(' '),
          phases: pl.dealer_phases.map do |ph|
            { name: ph.name, status: ph.status, estimated_start_date: ph.estimated_start_date, estimated_completion_date: ph.estimated_completion_date,
              tasks: ph.project_phase_tasks.map(&:name) }
          end,
          installer_project_id: pl.installer_project_id,
          installer_project_name: pl.installer_project&.name,
          billed: pl.dealer_bill_id.present?,
          installer_invoice_id: pl.installer_invoice_id,
          installer_invoice_number: pl.installer_invoice&.invoice_number
        }
      end
    end
  end
end
