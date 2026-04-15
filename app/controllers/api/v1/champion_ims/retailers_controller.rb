# frozen_string_literal: true

# CRUD for Champion IMS retailer feed configurations.
# Companies can have multiple retailers; each one is a single Navision ID
# that gets synced independently.
module Api
  module V1
    module ChampionIms
      class RetailersController < ApplicationController
        include ModuleAccessRequired

        before_action :authenticate
        before_action :set_company_scope
        before_action :set_retailer, only: %i[show update destroy sync_now]

        require_module! 'inventory.champion_ims'

        # GET /api/v1/champion_ims/retailers
        def index
          return unless authorize_action!('inventory', 'read')

          retailers = @company.champion_ims_retailers.order(:retailer_name, :retailer_navision_id)
          render json: retailers.map { |r| retailer_json(r) }
        end

        # GET /api/v1/champion_ims/retailers/:id
        def show
          return unless authorize_action!('inventory', 'read')
          render json: retailer_json(@retailer)
        end

        # POST /api/v1/champion_ims/retailers
        def create
          return unless authorize_action!('inventory', 'create')

          retailer = @company.champion_ims_retailers.build(retailer_params)

          if retailer.save
            render json: retailer_json(retailer), status: :created
          else
            render json: { errors: retailer.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH/PUT /api/v1/champion_ims/retailers/:id
        def update
          return unless authorize_action!('inventory', 'update')

          if @retailer.update(retailer_params)
            render json: retailer_json(@retailer)
          else
            render json: { errors: @retailer.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/v1/champion_ims/retailers/:id
        def destroy
          return unless authorize_action!('inventory', 'delete')

          @retailer.destroy
          head :no_content
        end

        # POST /api/v1/champion_ims/retailers/:id/sync_now
        # Enqueues a sync job for this retailer immediately.
        def sync_now
          return unless authorize_action!('inventory', 'update')

          if @retailer.sync_running?
            render json: { error: 'Sync already in progress for this retailer' }, status: :conflict
            return
          end

          ChampionImsSyncJob.perform_later(@retailer.id, trigger: 'manual')
          render json: {
            message: "Sync queued for #{@retailer.display_label}",
            retailer: retailer_json(@retailer)
          }, status: :accepted
        end

        private

        def set_retailer
          @retailer = @company.champion_ims_retailers.find_by(id: params[:id])
          render json: { error: 'Retailer not found' }, status: :not_found unless @retailer
        end

        # Never permit :company_id - tenant isolation is enforced via @company scope.
        def retailer_params
          params.require(:retailer).permit(
            :retailer_navision_id,
            :retailer_name,
            :retailer_city,
            :retailer_state,
            :location_id,
            :apply_to_all_locations,
            :active,
            :sync_frequency
          )
        end

        def retailer_json(retailer)
          {
            id:                     retailer.id,
            retailer_navision_id:   retailer.retailer_navision_id,
            retailer_name:          retailer.retailer_name,
            retailer_city:          retailer.retailer_city,
            retailer_state:         retailer.retailer_state,
            location_id:            retailer.location_id,
            apply_to_all_locations: retailer.apply_to_all_locations,
            active:                 retailer.active,
            sync_frequency:         retailer.sync_frequency,
            last_sync_at:           retailer.last_sync_at,
            last_sync_status:       retailer.last_sync_status,
            last_sync_error:        retailer.last_sync_error,
            last_sync_stats:        retailer.last_sync_stats,
            next_scheduled_sync_at: retailer.next_scheduled_sync_at,
            created_at:             retailer.created_at,
            updated_at:             retailer.updated_at
          }
        end
      end
    end
  end
end
