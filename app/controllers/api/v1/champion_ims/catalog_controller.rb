# frozen_string_literal: true

# Read-only browse endpoint for Champion floor plans in the shared catalog.
# Returns all FloorPlans that belong to the Champion Homes manufacturer,
# regardless of which company or retailer originally synced them - the
# catalog is global, not per-tenant.
#
# Used by the frontend "Champion Catalog" tab for bulk-import selection
# (coming in Prompt 3).
module Api
  module V1
    module ChampionIms
      class CatalogController < ApplicationController
        include ModuleAccessRequired

        before_action :authenticate
        before_action :set_company_scope

        require_module! 'inventory.champion_ims'

        # GET /api/v1/champion_ims/catalog
        # Query params:
        #   search   - filter by name/model_code/series (ILIKE)
        #   page     - default 1
        #   per_page - default 50, max 200
        def index
          return unless authorize_action!('inventory', 'read')

          manufacturer = Manufacturer.find_by(name: 'Champion Homes')
          unless manufacturer
            render json: { items: [], meta: empty_meta }
            return
          end

          scope = FloorPlan.where(manufacturer_id: manufacturer.id, is_active: true)

          # Count BEFORE search for stats-style totals
          all_count = scope.count

          if params[:search].present?
            term = "%#{params[:search]}%"
            scope = scope.where(
              'name ILIKE ? OR model_code ILIKE ? OR series ILIKE ? OR brand ILIKE ?',
              term, term, term, term
            )
          end

          filtered_count = scope.count

          page     = (params[:page] || 1).to_i.clamp(1, 10_000)
          per_page = [(params[:per_page] || 50).to_i, 200].min
          per_page = 50 if per_page < 1

          scope = scope.order(:name).offset((page - 1) * per_page).limit(per_page)

          render json: {
            items: scope.map { |fp| floor_plan_json(fp) },
            meta: {
              total:          filtered_count,
              page:           page,
              per_page:       per_page,
              total_pages:    (filtered_count.to_f / per_page).ceil,
              stats:          { total: all_count }
            }
          }
        end

        private

        def floor_plan_json(fp)
          {
            id:               fp.id,
            name:             fp.name,
            model_code:       fp.model_code,
            series:           fp.series,
            brand:            fp.brand,
            home_type:        fp.home_type,
            beds:             fp.beds,
            baths:            fp.baths,
            sqft:             fp.sqft,
            width_feet:       fp.width_feet,
            length_feet:      fp.length_feet,
            primary_image:    fp.primary_image_url,
            virtual_tour_url: fp.virtual_tour_url,
            last_scraped_at:  fp.last_scraped_at,
            created_at:       fp.created_at,
            updated_at:       fp.updated_at
          }
        end

        def empty_meta
          {
            total:       0,
            page:        1,
            per_page:    50,
            total_pages: 0,
            stats:       { total: 0 }
          }
        end
      end
    end
  end
end
