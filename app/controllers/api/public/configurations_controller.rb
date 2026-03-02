# frozen_string_literal: true

module Api
  module Public
    class ConfigurationsController < ApplicationController
      skip_before_action :authenticate

      # GET /api/public/configurations/:token
      def show
        @configuration = Configuration.find_by!(public_token: params[:token])

        # Track first view
        @configuration.update_column(:viewed_at, Time.current) if @configuration.viewed_at.nil?

        render json: public_configuration_json(@configuration)
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Configuration not found' }, status: :not_found
      end

      private

      def public_configuration_json(config)
        {
          configuration: {
            id: config.id,
            name: config.name,
            floor_plan: {
              name: config.floor_plan.name,
              model_code: config.floor_plan.model_code,
              manufacturer: config.floor_plan.manufacturer.name,
              beds: config.floor_plan.beds,
              baths: config.floor_plan.baths,
              sqft: config.floor_plan.sqft,
              images: config.floor_plan.images_array
            },
            selected_options: config.selected_options
                                    .includes(:option_category)
                                    .group_by { |opt| opt.option_category.name }
                                    .map do |category_name, options|
              {
                category: category_name,
                options: options.map { |opt| { name: opt.name } }
              }
            end,
            price_range: format_price_range(config.price_range_low, config.price_range_high),
            note: 'Contact us for exact pricing and availability'
          },
          company: {
            name: config.company.name
          }
        }
      end

      def format_price_range(low, high)
        return nil if low.nil? && high.nil?
        "#{format_currency(low)} - #{format_currency(high)}"
      end

      def format_currency(amount)
        return '$0' if amount.nil?
        "$#{amount.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
      end
    end
  end
end
