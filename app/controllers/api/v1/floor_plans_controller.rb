# frozen_string_literal: true

module Api
  module V1
    class FloorPlansController < ApplicationController
      before_action :set_company_scope
      include ConfiguratorAccess

      # GET /api/v1/floor_plans
      def index
        return unless authorize_action!('configurator', 'read')

        floor_plans = FloorPlan.active
                               .includes(:manufacturer, :factory)
                               .order('manufacturers.name, floor_plans.name')

        floor_plans = floor_plans.where(manufacturer_id: params[:manufacturer_id]) if params[:manufacturer_id].present?
        floor_plans = floor_plans.where('beds >= ?', params[:min_beds]) if params[:min_beds].present?
        floor_plans = floor_plans.where('beds <= ?', params[:max_beds]) if params[:max_beds].present?
        floor_plans = floor_plans.where('baths >= ?', params[:min_baths]) if params[:min_baths].present?
        floor_plans = floor_plans.where('sqft >= ?', params[:min_sqft]) if params[:min_sqft].present?
        floor_plans = floor_plans.where('sqft <= ?', params[:max_sqft]) if params[:max_sqft].present?

        if params[:search].present?
          floor_plans = floor_plans.where(
            'floor_plans.name ILIKE ? OR floor_plans.model_code ILIKE ? OR floor_plans.series ILIKE ?',
            "%#{params[:search]}%", "%#{params[:search]}%", "%#{params[:search]}%"
          )
        end

        company_plan_ids = @company.floor_plans.pluck(:id)

        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        total_count = floor_plans.count
        floor_plans = floor_plans.offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: floor_plans.map { |fp| floor_plan_json(fp, company_plan_ids.include?(fp.id)) },
          meta: {
            total: total_count,
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      # GET /api/v1/floor_plans/:id
      def show
        return unless authorize_action!('configurator', 'read')

        floor_plan = FloorPlan.active.includes(:manufacturer, :factory, option_categories: :floor_plan_options).find(params[:id])

        render json: floor_plan_detail_json(floor_plan)
      end

      private

      def floor_plan_json(floor_plan, in_company_catalog)
        {
          id: floor_plan.id,
          name: floor_plan.name,
          model_code: floor_plan.model_code,
          series: floor_plan.series,
          manufacturer: {
            id: floor_plan.manufacturer.id,
            name: floor_plan.manufacturer.name
          },
          factory: floor_plan.factory ? {
            id: floor_plan.factory.id,
            name: floor_plan.factory.name,
            city: floor_plan.factory.city,
            state: floor_plan.factory.state
          } : nil,
          beds: floor_plan.beds,
          baths: floor_plan.baths,
          sqft: floor_plan.sqft,
          dimensions: "#{floor_plan.width_feet}' x #{floor_plan.length_feet}'",
          images: floor_plan.images_array || [],
          base_price_range: {
            low: floor_plan.base_price_low,
            high: floor_plan.base_price_high
          },
          suggested_retail_range: {
            low: floor_plan.suggested_retail_low,
            high: floor_plan.suggested_retail_high
          },
          in_company_catalog: in_company_catalog
        }
      end

      def floor_plan_detail_json(floor_plan)
        floor_plan_json(floor_plan, @company.floor_plans.exists?(floor_plan.id)).merge(
          specifications: floor_plan.specifications,
          options_by_category: floor_plan.options_by_category
        )
      end
    end
  end
end
