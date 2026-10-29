# frozen_string_literal: true

module Api
  module V1
    # Bids & Quotes (E87): every bid this company asked for and every quote it
    # asked a linked installer for, across all projects, plus the quotes dealers
    # asked of it as an installer. Acting on a bid (award, undo, cancel) still
    # goes through ProjectBidRequestsController; this only lists.
    class BidsBoardController < ApplicationController
      before_action :set_company_scope

      # Dealer-side stages, in tab order. Installer side reuses them with its
      # own words (to_answer, submitted, won, not_awarded).
      OUT_STAGES = %w[waiting ready awarded declined cancelled].freeze
      IN_STAGES = %w[to_answer submitted won not_awarded].freeze
      # The list itself leads with what needs a decision.
      OUT_SORT = %w[ready waiting awarded declined cancelled].freeze

      # GET /api/v1/bids_board
      def index
        return unless authorize_action!('deals', 'read')

        outgoing = bid_rows + quote_rows_out
        outgoing = filter_by_location(outgoing)
        incoming = quote_rows_in

        render json: {
          outgoing: outgoing.sort_by { |r| [OUT_SORT.index(r[:stage]) || 9, -(r[:updated_at] || r[:created_at]).to_i] },
          incoming: incoming.sort_by { |r| [IN_STAGES.index(r[:stage]) || 9, -(r[:updated_at] || r[:created_at]).to_i] },
          counts: {
            outgoing: OUT_STAGES.index_with { |s| outgoing.count { |r| r[:stage] == s } },
            incoming: IN_STAGES.index_with { |s| incoming.count { |r| r[:stage] == s } }
          }
        }
      end

      # GET /api/v1/bids_board/counts (the menu badge)
      def counts
        return unless authorize_action!('deals', 'read')

        ready = @company.project_bid_requests.open.joins(:bids).where(project_bids: { status: 'submitted' }).distinct.count
        ready += ProjectLinkChange.pending.where(kind: 'price').joins(:project_link)
                                  .where(project_links: { dealer_company_id: @company.id, status: %w[offered accepted] }).count
        to_answer = quote_links_in.count { |pl| in_stage(pl) == 'to_answer' }
        render json: { ready: ready, to_answer: to_answer, total: ready + to_answer }
      end

      private

      def bid_rows
        requests = @company.project_bid_requests
                           .includes(:project_phase, project: :deal, bids: %i[vendor entered_by])
                           .where(projects: { is_deleted: [false, nil] }).references(:projects)
                           .order(created_at: :desc).limit(500)
        requests.map do |r|
          r.as_api_json(include_project: true).merge(
            source: 'bid', key: "bid-#{r.id}", stage: out_stage_for_request(r), location_id: r.project.location_id,
            updated_at: r.updated_at
          )
        end
      end

      def out_stage_for_request(request)
        case request.status
        when 'awarded' then 'awarded'
        when 'cancelled' then 'cancelled'
        else
          bids = request.bids
          if bids.any? { |b| b.status == 'submitted' } then 'ready'
          elsif bids.any? && bids.all? { |b| b.status == 'declined' } then 'declined'
          else 'waiting'
          end
        end
      end

      # Jobs this dealer sent a linked installer with "Ask them to quote".
      def quote_rows_out
        links = ProjectLink.where(dealer_company_id: @company.id, price_source: 'quote')
                           .includes(:installer_company, :link_changes, dealer_project: :deal)
                           .order(created_at: :desc).limit(300)
        links.map do |pl|
          price = latest_price(pl)
          stage = case pl.status
                  when 'cancelled' then 'cancelled'
                  when 'declined' then 'declined'
                  else
                    if price.nil? then 'waiting'
                    else { 'pending' => 'ready', 'approved' => 'awarded', 'declined' => 'declined', 'withdrawn' => 'waiting' }[price.status]
                    end
                  end
          quote_row(pl, price, stage, counterpart: pl.installer_company.name).merge(location_id: pl.dealer_project.location_id)
        end
      end

      # Jobs dealers sent this company (as an installer) asking for its quote.
      def quote_rows_in
        quote_links_in.map do |pl|
          quote_row(pl, latest_price(pl), in_stage(pl), counterpart: pl.dealer_company.name)
        end
      end

      def quote_links_in
        @quote_links_in ||= ProjectLink.where(installer_company_id: @company.id, price_source: 'quote')
                                       .where.not(status: 'cancelled')
                                       .includes(:dealer_company, :link_changes, :dealer_project)
                                       .order(created_at: :desc).limit(300).to_a
      end

      def in_stage(pl)
        return 'not_awarded' if pl.status == 'declined'

        price = latest_price(pl)
        return 'to_answer' if price.nil? || price.status == 'withdrawn'

        { 'pending' => 'submitted', 'approved' => 'won', 'declined' => 'not_awarded' }[price.status]
      end

      def latest_price(pl)
        pl.link_changes.select { |c| c.kind == 'price' }.max_by(&:number)
      end

      # The installer sees the job's scope and the dealer's name, never the
      # dealer's customer (the job carries that only once accepted).
      def quote_row(pl, price, stage, counterpart:)
        mine = pl.dealer_company_id == @company.id
        project = mine ? pl.dealer_project : pl.installer_project
        {
          source: 'installer_quote', key: "quote-#{pl.id}", id: pl.id, stage: stage,
          title: pl.scope_label, phase_name: pl.dealer_phase&.name, status: pl.status,
          counterpart: counterpart,
          project_id: project&.id, project_name: project&.name,
          customer_name: mine ? pl.dealer_project.customer_display_name : nil,
          deal_id: mine ? pl.dealer_project.deal_id : nil,
          amount: price&.amount&.to_f, price_status: price&.status, decline_reason: price&.decline_reason || pl.decline_reason,
          note: pl.note, created_at: pl.created_at, updated_at: [pl.updated_at, price&.updated_at].compact.max,
          link: mine ? (pl.dealer_project.deal_id ? "/deals/#{pl.dealer_project.deal_id}?tab=progress" : "/deals/projects/#{pl.dealer_project_id}") : '/linked-companies?view=jobs'
        }
      end

      # Same rule as the project lists: company-tier admins see everything,
      # everyone else their locations. Rows with no location are kept.
      def filter_by_location(rows)
        if current_user.uses_rbac? && !current_user.effective_admin?
          ids = permission_service.accessible_location_ids
          rows = rows.select { |r| r[:location_id].nil? || ids.include?(r[:location_id]) }
        end
        rows = rows.select { |r| r[:location_id].nil? || r[:location_id] == Current.location_id } if Current.location_filtered?
        rows
      end
    end
  end
end
