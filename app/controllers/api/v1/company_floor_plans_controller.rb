# frozen_string_literal: true

module Api
  module V1
    class CompanyFloorPlansController < ApplicationController
      before_action :set_company_scope
      include ConfiguratorAccess
      before_action :set_company_floor_plan, only: [:show, :update, :destroy]

      # GET /api/v1/company_floor_plans
      def index
        return unless authorize_action!('configurator', 'read')

        company_floor_plans = @company.company_floor_plans
                                      .includes(floor_plan: [:manufacturer, :factory])
                                      .ordered

        company_floor_plans = company_floor_plans.visible if params[:visible_only] == 'true'

        render json: {
          items: company_floor_plans.map { |cfp| company_floor_plan_json(cfp) }
        }
      end

      # GET /api/v1/company_floor_plans/:id
      def show
        return unless authorize_action!('configurator', 'read')

        render json: company_floor_plan_json(@company_floor_plan)
      end

      # POST /api/v1/company_floor_plans
      def create
        return unless authorize_action!('configurator', 'create')

        floor_plan_id = params.dig(:company_floor_plan, :floor_plan_id) || params[:floor_plan_id]
        return render json: { error: 'floor_plan_id is required' }, status: :unprocessable_entity if floor_plan_id.blank?

        floor_plan = FloorPlan.find(floor_plan_id)

        company_floor_plan = @company.company_floor_plans.find_or_initialize_by(
          floor_plan: floor_plan
        )
        company_floor_plan.assign_attributes(company_floor_plan_params)

        if company_floor_plan.save
          render json: company_floor_plan_json(company_floor_plan), status: :created
        else
          render json: { errors: company_floor_plan.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/company_floor_plans/:id
      def update
        return unless authorize_action!('configurator', 'update')

        if @company_floor_plan.update(company_floor_plan_params)
          render json: company_floor_plan_json(@company_floor_plan)
        else
          render json: { errors: @company_floor_plan.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/company_floor_plans/:id
      def destroy
        return unless authorize_action!('configurator', 'delete')

        @company_floor_plan.update!(is_visible: false)
        head :no_content
      end

      private

      def set_company_floor_plan
        @company_floor_plan = @company.company_floor_plans.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def company_floor_plan_params
        params.require(:company_floor_plan).permit(
          :is_visible, :dealer_cost, :retail_price,
          :markup_type, :markup_value,
          :custom_name, :custom_description,
          :display_order
        )
      end

      def company_floor_plan_json(cfp)
        fp = cfp.floor_plan

        {
          id: cfp.id,
          floor_plan_id: fp.id,
          name: cfp.custom_name.presence || fp.name,
          model_code: fp.model_code,
          manufacturer: fp.manufacturer.name,
          is_visible: cfp.is_visible,
          display_order: cfp.display_order,
          pricing: {
            dealer_cost: cfp.dealer_cost,
            retail_price: cfp.retail_price,
            markup_type: cfp.markup_type,
            markup_value: cfp.markup_value
          },
          floor_plan: {
            id: fp.id,
            bedrooms: fp.beds,
            bathrooms: fp.baths,
            sqft: fp.sqft,
            series: fp.series,
            images: fp.images_array&.first(1) || []
          }
        }
      end
    end
  end
end
