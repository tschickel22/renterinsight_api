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
        company = config.company
        fp = config.floor_plan

        # Build selected options grouped by category
        selected_options_grouped = config.selected_options
                                        .includes(:option_category)
                                        .group_by { |opt| opt.option_category }
                                        .sort_by { |cat, _| cat.display_order }
                                        .map do |category, options|
          {
            category_id: category.id,
            category_name: category.name,
            options: options.map { |opt|
              {
                id: opt.id,
                name: opt.name,
                description: opt.description,
                price_impact_low: opt.price_impact_low,
                price_impact_high: opt.price_impact_high
              }
            }
          }
        end

        # Determine if pricing is fixed or range
        has_fixed_pricing = (config.price_range_low.present? &&
                             config.price_range_high.present? &&
                             config.price_range_low == config.price_range_high)

        # Company branding
        branding = company.branding_settings rescue {}

        {
          configuration: {
            id: config.id,
            name: config.name,
            status: config.status,
            notes: config.notes,
            created_at: config.created_at,
            floor_plan: {
              name: fp.name,
              model_code: fp.model_code,
              manufacturer_name: fp.manufacturer&.name,
              bedrooms: fp.beds,
              bathrooms: fp.baths,
              sqft: fp.sqft,
              width_ft: fp.width_ft,
              length_ft: fp.length_ft,
              sections: fp.sections,
              description: fp.description,
              primary_image_url: fp.primary_image_url,
              floor_plan_image_url: fp.floor_plan_image_url,
              images: fp.images_array
            },
            selected_options: selected_options_grouped,
            pricing: {
              total_price_low: config.price_range_low,
              total_price_high: config.price_range_high,
              base_price_low: config.base_price || config.price_range_low,
              base_price_high: config.base_price || config.price_range_high,
              options_total_low: config.options_total || 0,
              options_total_high: config.options_total || 0,
              has_fixed_pricing: has_fixed_pricing
            }
          },
          company: {
            name: company.name,
            # Company has no logo_url/website methods — logo lives in branding
            # settings (Company#logo) and the web address is Company#domain.
            logo_url: branding.dig('logo_url') || company.logo,
            phone: company.phone,
            email: company.email,
            website: company.domain
          }
        }
      end
    end
  end
end
