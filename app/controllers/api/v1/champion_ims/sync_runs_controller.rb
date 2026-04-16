# frozen_string_literal: true

# Read-only history endpoints for Champion IMS feed syncs.
#
# Routes (mounted under retailers in routes.rb):
#   GET /api/v1/champion_ims/retailers/:retailer_id/sync_runs
#       List recent sync runs for one retailer (paginated, recent-first)
#
#   GET /api/v1/champion_ims/retailers/:retailer_id/sync_runs/:id
#       Show one run with all its events. Optional ?event_type=updated
#       to filter the events list.
module Api
  module V1
    module ChampionIms
      class SyncRunsController < ApplicationController
        include ModuleAccessRequired

        before_action :authenticate
        before_action :set_company_scope
        before_action :set_retailer
        before_action :set_run, only: %i[show]

        require_module! 'inventory.champion_ims'

        # GET /api/v1/champion_ims/retailers/:retailer_id/sync_runs
        #   ?per_page=50  (default 25, max 100)
        #   ?page=1
        def index
          return unless authorize_action!('inventory', 'read')

          per_page = [[params[:per_page].to_i, 25].max, 100].min
          page     = [params[:page].to_i, 1].max

          runs = @retailer.sync_runs.recent.limit(per_page).offset((page - 1) * per_page)
          total = @retailer.sync_runs.count

          render json: {
            sync_runs:  runs.map { |run| run_summary_json(run) },
            pagination: {
              page:        page,
              per_page:    per_page,
              total:       total,
              total_pages: (total.to_f / per_page).ceil
            }
          }
        end

        # GET /api/v1/champion_ims/retailers/:retailer_id/sync_runs/:id
        #   ?event_type=added|updated|unchanged|tombstoned|protected|skipped
        def show
          return unless authorize_action!('inventory', 'read')

          events_scope = @run.events.order(created_at: :asc)

          if params[:event_type].present?
            events_scope = events_scope.where(event_type: params[:event_type])
          end

          render json: {
            sync_run: run_detail_json(@run),
            events:   events_scope.map { |e| event_json(e) }
          }
        end

        private

        def set_retailer
          @retailer = @company.champion_ims_retailers.find_by(id: params[:retailer_id])
          render json: { error: 'Retailer not found' }, status: :not_found unless @retailer
        end

        def set_run
          @run = @retailer.sync_runs.find_by(id: params[:id])
          render json: { error: 'Sync run not found' }, status: :not_found unless @run
        end

        # Lightweight summary for the list view (no events array).
        def run_summary_json(run)
          {
            id:                 run.id,
            status:             run.status,
            started_at:         run.started_at,
            finished_at:        run.finished_at,
            duration_ms:        run.duration_ms,
            trigger:            run.trigger,
            no_op:              run.no_op?,
            catalog_added:      run.catalog_added,
            catalog_updated:    run.catalog_updated,
            catalog_unchanged:  run.catalog_unchanged,
            catalog_tombstoned: run.catalog_tombstoned,
            catalog_protected:  run.catalog_protected,
            vehicles_skipped:   run.vehicles_skipped,
            total:              run.total,
            error_message:      run.error_message
          }
        end

        # Same shape as summary — kept as a separate method so it's easy to
        # add detail-only fields later (e.g., feed payload size) without
        # bloating the list response.
        def run_detail_json(run)
          run_summary_json(run)
        end

        def event_json(event)
          {
            id:                event.id,
            event_type:        event.event_type,
            display_name:      event.display_name,
            inventory_id:      event.inventory_id,
            vehicle_id:        event.vehicle_id,
            champion_model_id: event.champion_model_id,
            # API exposes this as `changes` for FE simplicity; the column was
            # renamed to `field_changes` to avoid AR Dirty collision.
            changes:           event.field_changes || {},
            change_count:      event.change_count,
            reason:            event.reason,
            created_at:        event.created_at
          }
        end
      end
    end
  end
end
