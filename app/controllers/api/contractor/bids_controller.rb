# frozen_string_literal: true

module Api
  module Contractor
    # Bid requests in the portal (E68 step 4). A contractor sees only their own
    # bids, and only what a bidder needs: no customer, deal or other bids.
    class BidsController < BaseController
      before_action :set_bid, except: :index

      # GET /api/contractor/bids
      def index
        bids = ProjectBid.where(vendor_id: all_contractor_ids)
                         .includes(:company, project_bid_request: %i[project project_phase])
                         .order(created_at: :desc).limit(200).to_a
        # Waiting on me first, then the rest newest first.
        bids = bids.sort_by { |b| [actionable?(b) ? 0 : 1, -b.created_at.to_i] }
        render json: { items: bids.map { |b| bid_json(b) } }
      end

      # GET /api/contractor/bids/:id
      def show
        render json: { bid: bid_json(@bid, detail: true) }
      end

      # POST /api/contractor/bids/:id/submit { amount, can_start_on, duration_days, notes }
      def submit
        ProjectBidService.new(@bid.company).submit!(
          @bid, amount: params[:amount], can_start_on: params[:can_start_on],
                duration_days: params[:duration_days], notes: params[:notes]
        )
        render json: { bid: bid_json(@bid.reload, detail: true) }
      rescue ProjectBidService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/contractor/bids/:id/decline { notes }
      def decline
        ProjectBidService.new(@bid.company).decline!(@bid, notes: params[:notes])
        render json: { bid: bid_json(@bid.reload, detail: true) }
      rescue ProjectBidService::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def set_bid
        @bid = ProjectBid.where(vendor_id: all_contractor_ids).find_by(id: params[:id])
        render json: { error: 'Bid not found' }, status: :not_found unless @bid
      end

      def actionable?(bid)
        bid.project_bid_request.open? && bid.status.in?(%w[invited submitted])
      end

      # What the contractor sees of their own bid. A bid that went to someone
      # else reads "not_awarded"; one on a cancelled request reads "closed".
      def bid_json(bid, detail: false)
        request = bid.project_bid_request
        project = request.project
        status = request.status == 'cancelled' && bid.status != 'awarded' ? 'closed' : bid.status
        json = {
          id: bid.id,
          status: status,
          open: request.open?,
          company_name: bid.company.name,
          title: request.title,
          # The project name often carries the customer's name; bidders see it once the job is theirs.
          project_name: bid.status == 'awarded' ? project.name : nil,
          phase_name: request.project_phase&.name,
          city: [project.delivery_city, project.delivery_state].compact_blank.join(', ').presence,
          bids_due_on: request.bids_due_on,
          start_wanted_on: request.start_wanted_on,
          amount: bid.amount&.to_f,
          can_start_on: bid.can_start_on,
          duration_days: bid.duration_days,
          submitted_at: bid.submitted_at,
          invited_at: bid.invited_at,
          # Once awarded the job is theirs and shows under Projects.
          project_id: bid.status == 'awarded' ? project.id : nil
        }
        return json unless detail

        tasks = if request.project_phase
          request.project_phase.project_phase_tasks.map(&:name)
        else
          []
        end
        json.merge(scope: request.scope, tasks: tasks, notes: bid.notes)
      end
    end
  end
end
