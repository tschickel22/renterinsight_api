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
      # A bid staff type in for a contractor: { bid_id, amount, can_start_on, duration_days, notes, reason }
      # reason is required to change a bid the contractor sent themselves.
      def record_bid
        return unless authorize_action!('deals', 'update')

        bid = @request.bids.find_by(id: params[:bid_id])
        return render(json: { error: 'Bid not found' }, status: :not_found) unless bid

        service.submit!(bid, amount: params[:amount], can_start_on: params[:can_start_on],
                             duration_days: params[:duration_days], notes: params[:notes], entered_by: current_user,
                             reason: params[:reason])
        render json: { bid_request: request_json(@request.reload) }
      rescue ProjectBidService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/projects/:project_id/bid_requests/:id/award { bid_id, notify_others, note }
      # note goes to the winner with the award.
      def award
        return unless authorize_action!('deals', 'update')

        bid = @request.bids.find_by(id: params[:bid_id])
        return render(json: { error: 'Bid not found' }, status: :not_found) unless bid

        notify = params.key?(:notify_others) ? ActiveModel::Type::Boolean.new.cast(params[:notify_others]) : true
        service.award!(@request, bid, notify_others: notify, note: params[:note])
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
        request.as_api_json
      end
    end
  end
end
