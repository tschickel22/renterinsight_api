# frozen_string_literal: true

module Api
  module V1
    class ConfigurationsController < ApplicationController
      before_action :set_company_scope
      include ConfiguratorAccess
      before_action :set_configuration, only: [:show, :update, :destroy, :calculate_price, :share]

      # GET /api/v1/configurations
      def index
        return unless authorize_action!('configurator', 'read')

        configurations = @company.configurations
                                 .includes(:floor_plan, :user)
                                 .order(created_at: :desc)

        configurations = configurations.by_status(params[:status]) if params[:status].present?

        if params[:configurable_type].present? && params[:configurable_id].present?
          configurations = configurations.where(
            configurable_type: params[:configurable_type],
            configurable_id: params[:configurable_id]
          )
        end

        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        total_count = configurations.count
        configurations = configurations.offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: configurations.map { |config| configuration_summary_json(config) },
          meta: {
            total: total_count,
            page: page,
            per_page: per_page
          }
        }
      end

      # GET /api/v1/configurations/:id
      def show
        return unless authorize_action!('configurator', 'read')

        render json: configuration_detail_json(@configuration)
      end

      # POST /api/v1/configurations
      def create
        return unless authorize_action!('configurator', 'create')

        @configuration = @company.configurations.build(configuration_params)
        @configuration.user = current_user
        @configuration.status = 'draft'

        if @configuration.save
          render json: configuration_detail_json(@configuration), status: :created
        else
          render json: { errors: @configuration.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/configurations/:id
      def update
        return unless authorize_action!('configurator', 'update')

        if @configuration.update(configuration_params)
          render json: configuration_detail_json(@configuration)
        else
          render json: { errors: @configuration.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/configurations/:id/calculate_price
      def calculate_price
        return unless authorize_action!('configurator', 'read')

        pricing = ConfiguratorPricingService.calculate_for_company(
          @configuration.floor_plan,
          @company,
          @configuration.selections || []
        )

        render json: pricing
      end

      # POST /api/v1/configurations/:id/share
      def share
        return unless authorize_action!('configurator', 'update')

        @configuration.update!(
          status: 'shared',
          shared_at: Time.current
        )

        public_url = "#{ENV['FRONTEND_URL']}/c/#{@configuration.public_token}"

        render json: {
          public_token: @configuration.public_token,
          public_url: public_url
        }
      end

      # DELETE /api/v1/configurations/:id
      def destroy
        return unless authorize_action!('configurator', 'delete')

        @configuration.update!(status: 'archived')
        head :no_content
      end

      private

      def set_configuration
        @configuration = @company.configurations.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def configuration_params
        params.require(:configuration).permit(
          :floor_plan_id, :name,
          :configurable_type, :configurable_id,
          :customer_name, :customer_email, :customer_phone,
          selections: []
        )
      end

      def configuration_summary_json(config)
        {
          id: config.id,
          name: config.name,
          floor_plan: {
            id: config.floor_plan.id,
            name: config.floor_plan.name,
            model_code: config.floor_plan.model_code
          },
          price_range: {
            low: config.price_range_low,
            high: config.price_range_high
          },
          status: config.status,
          customer_name: config.customer_name,
          created_by: config.user&.name,
          created_at: config.created_at,
          shared_at: config.shared_at
        }
      end

      def configuration_detail_json(config)
        configuration_summary_json(config).merge(
          floor_plan_detail: {
            beds: config.floor_plan.beds,
            baths: config.floor_plan.baths,
            sqft: config.floor_plan.sqft,
            images: config.floor_plan.images_array
          },
          selections: config.selections,
          selected_options: config.selected_options.includes(:option_category).map { |opt|
            {
              id: opt.id,
              name: opt.name,
              category: opt.option_category.name,
              price_impact_low: opt.price_impact_low,
              price_impact_high: opt.price_impact_high
            }
          },
          pricing: {
            base_price: config.base_price,
            options_total: config.options_total,
            total_price: config.total_price,
            price_range_low: config.price_range_low,
            price_range_high: config.price_range_high
          },
          customer_info: {
            name: config.customer_name,
            email: config.customer_email,
            phone: config.customer_phone
          },
          public_token: config.public_token,
          configurable: config.configurable ? {
            type: config.configurable_type,
            id: config.configurable_id
          } : nil
        )
      end
    end
  end
end
