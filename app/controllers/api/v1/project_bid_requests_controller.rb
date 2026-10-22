# frozen_string_literal: true

module Api
  module V1
    # Bids on a project's phases (E68 step 4). The work happens in
    # ProjectBidService; this controller checks access and shapes the JSON.
    # Project actions use the 'deals' permission, as ProjectsController does.
    class ProjectBidRequestsController < ApplicationController
      before_action :set_company_scope
      before_action :set_project
      before_action :set_request, except: %i[index create]

      # GET /api/v1/projects/:project_id/bid_requests
      def index
        return unless authorize_action!('deals', 'read')

        requests = @project.project_bid_requests.includes(:project_phase, bids: %i[vendor entered_by]).order(created_at: :desc)
        render json: { bid_requests: requests.map { |r| request_json(r) } }
      end

      # POST /api/v1/projects/:project_id/bid_requests
      def create
        return unless authorize_action!('deals', 'update')

        phase = nil
        if params[:project_phase_id].present?
          phase = @project.project_phases.find_by(id: params[:project_phase_id])
          return render(json: { error: 'Phase not found' }, status: :not_found) unless phase
        end
        request = service.send_request!(
          project: @project, phase: phase, title: params[:title], scope: params[:scope],
          bids_due_on: date_param(:bids_due_on), start_wanted_on: date_param(:start_wanted_on),
          vendor_ids: params[:vendor_ids]
        )
        render json: { bid_request: request_json(request.reload) }, status: :created
      rescue ProjectBidService::Error, ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/projects/:project_id/bid_requests/:id/invite
      def invite
        return unless authorize_action!('deals', 'update')

        service.invite_more!(@request, params[:vendor_ids])
        render json: { bid_request: request_json(@request.reload) }
      rescue ProjectBidService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/projects/:project_id/bid_requests/:id/record_bid
      # A bid staff type in for a contractor: { bid_id, amount, can_start_on, duration_days, notes }
      def record_bid
        return unless authorize_action!('deals', 'update')

        bid = @request.bids.find_by(id: params[:bid_id])
        return render(json: { error: 'Bid not found' }, status: :not_found) unless bid

        service.submit!(bid, amount: params[:amount], can_start_on: params[:can_start_on],
                             duration_days: params[:duration_days], notes: params[:notes], entered_by: current_user)
        render json: { bid_request: request_json(@request.reload) }
      rescue ProjectBidService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/projects/:project_id/bid_requests/:id/award { bid_id, notify_others }
      def award
        return unless authorize_action!('deals', 'update')

        bid = @request.bids.find_by(id: params[:bid_id])
        return render(json: { error: 'Bid not found' }, status: :not_found) unless bid

        notify = params.key?(:notify_others) ? ActiveModel::Type::Boolean.new.cast(params[:notify_others]) : true
        service.award!(@request, bid, notify_others: notify)
        render json: { bid_request: request_json(@request.reload) }
      rescue ProjectBidService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/projects/:project_id/bid_requests/:id/undo_award
      def undo_award
        return unless authorize_action!('deals', 'update')

        service.undo_award!(@request)
        render json: { bid_request: request_json(@request.reload) }
      rescue ProjectBidService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/projects/:project_id/bid_requests/:id/cancel { notify }
      def cancel
        return unless authorize_action!('deals', 'update')

        notify = params.key?(:notify) ? ActiveModel::Type::Boolean.new.cast(params[:notify]) : true
        service.cancel!(@request, notify: notify)
        render json: { bid_request: request_json(@request.reload) }
      rescue ProjectBidService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def set_project
        @project = @company.projects.not_deleted.find(params[:project_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Project not found' }, status: :not_found
      end

      def set_request
        @request = @project.project_bid_requests.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Bid request not found' }, status: :not_found
      end

      def service
        ProjectBidService.new(@company, actor: current_user)
      end

      def date_param(key)
        return nil if params[key].blank?

        Date.parse(params[key].to_s)
      rescue Date::Error
        raise ArgumentError, "#{key.to_s.humanize} is not a valid date"
      end

      def request_json(request)
        bids = request.bids.sort_by { |b| [b.amount ? 0 : 1, b.amount.to_d, b.vendor.name.to_s] }
        lowest = bids.select { |b| b.status.in?(%w[submitted awarded not_awarded]) }.map { |b| b.amount.to_d }.min
        {
          id: request.id,
          title: request.title,
          scope: request.scope,
          status: request.status,
          project_phase_id: request.project_phase_id,
          phase_name: request.project_phase&.name,
          bids_due_on: request.bids_due_on,
          start_wanted_on: request.start_wanted_on,
          awarded_bid_id: request.awarded_bid_id,
          awarded_at: request.awarded_at,
          cancelled_at: request.cancelled_at,
          created_at: request.created_at,
          bids: bids.map do |b|
            {
              id: b.id,
              vendor_id: b.vendor_id,
              vendor_name: b.vendor.name,
              vendor_email: b.vendor.email,
              status: b.status,
              amount: b.amount&.to_f,
              lowest: lowest.present? && b.amount.present? && b.amount.to_d == lowest && b.status != 'declined',
              can_start_on: b.can_start_on,
              duration_days: b.duration_days,
              notes: b.notes,
              submitted_at: b.submitted_at,
              entered_by_name: b.entered_by&.full_name.presence || b.entered_by&.email,
              project_cost_item_id: b.project_cost_item_id
            }
          end
        }
      end
    end
  end
end
