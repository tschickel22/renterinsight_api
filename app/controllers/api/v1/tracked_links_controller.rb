# frozen_string_literal: true

module Api
  module V1
    class TrackedLinksController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/tracked_links?entity_type=Lead&entity_id=123
      def index
        links = @company.tracked_links

        if params[:entity_type].present? && params[:entity_id].present?
          links = links.where(entity_type: params[:entity_type], entity_id: params[:entity_id])
        end

        if params[:source_type].present? && params[:source_id].present?
          links = links.where(source_type: params[:source_type], source_id: params[:source_id])
        end

        links = links.order(created_at: :desc).limit(200)
        render json: links.map { |tl| index_json(tl) }
      end

      # GET /api/v1/tracked_links/:id
      def show
        link = @company.tracked_links.find_by(id: params[:id])
        unless link
          render json: { error: 'Not found' }, status: :not_found
          return
        end

        render json: index_json(link).merge(
          events: link.tracked_link_events.order(clicked_at: :desc).limit(200).map { |e|
            {
              id:         e.id,
              clicked_at: e.clicked_at&.iso8601,
              ip_address: e.ip_address,
              user_agent: e.user_agent
            }
          }
        )
      end

      # GET /api/v1/tracked_links/prospect_interest?entity_type=Lead&entity_id=123
      # Aggregates vehicle-tagged tracked-link clicks for a lead/contact and returns
      # the most-clicked vehicles together with engagement scoring.
      def prospect_interest
        return unless authorize_action!('leads', 'read')

        entity_type = params[:entity_type]
        entity_id   = params[:entity_id]

        if entity_type.blank? || entity_id.blank?
          render json: { error: 'entity_type and entity_id are required' }, status: :bad_request
          return
        end

        interest_data = @company.tracked_links
          .where(entity_type: entity_type, entity_id: entity_id)
          .where.not(vehicle_id: nil)
          .where('click_count > 0')
          .group(:vehicle_id)
          .select(
            'vehicle_id',
            'SUM(click_count) AS total_clicks',
            'MAX(last_clicked_at) AS last_viewed',
            'MIN(first_clicked_at) AS first_viewed',
            'COUNT(*) AS link_count'
          )
          .order(Arel.sql('SUM(click_count) DESC'))
          .limit(10)

        vehicle_ids = interest_data.map(&:vehicle_id)
        vehicles    = Vehicle.where(id: vehicle_ids).index_by(&:id)

        results = interest_data.filter_map do |row|
          vehicle = vehicles[row.vehicle_id]
          next unless vehicle

          last_viewed = row.last_viewed
          days_since  = last_viewed ? ((Time.current - last_viewed) / 1.day).round(1) : nil

          {
            vehicle_id:           row.vehicle_id,
            vehicle_name:         [vehicle.year, vehicle.make, vehicle.model].compact.join(' '),
            vehicle_status:       vehicle.status,
            sale_price:           vehicle.sale_price,
            primary_image:        extract_primary_image(vehicle),
            bedrooms:             vehicle.bedrooms,
            bathrooms:            vehicle.bathrooms,
            square_feet:          vehicle.square_feet,
            total_clicks:         row.total_clicks.to_i,
            last_viewed:          last_viewed,
            first_viewed:         row.first_viewed,
            days_since_last_view: days_since,
            engagement_level:     engagement_level(row.total_clicks.to_i, last_viewed)
          }
        end

        render json: { interest_data: results, total_vehicles_viewed: results.size }
      end

      private

      def engagement_level(clicks, last_clicked)
        return 'none' if clicks == 0
        recency_days = last_clicked ? ((Time.current - last_clicked) / 1.day) : 999
        if clicks >= 3 && recency_days <= 3
          'hot'
        elsif clicks >= 2 && recency_days <= 7
          'warm'
        elsif recency_days <= 14
          'lukewarm'
        else
          'cold'
        end
      end

      def extract_primary_image(vehicle)
        images = vehicle.images
        return nil if images.blank?
        parsed = images.is_a?(String) ? (JSON.parse(images) rescue nil) : images
        return nil unless parsed.is_a?(Array) && parsed.any?
        parsed.first.is_a?(Hash) ? parsed.first['url'] : parsed.first
      end

      def index_json(tl)
        {
          id:               tl.id,
          token:            tl.token,
          filename:         tl.filename,
          content_type:     tl.content_type,
          file_size:        tl.file_size,
          click_count:      tl.click_count.to_i,
          first_clicked_at: tl.first_clicked_at&.iso8601,
          last_clicked_at:  tl.last_clicked_at&.iso8601,
          source_type:      tl.source_type,
          source_id:        tl.source_id,
          entity_type:      tl.entity_type,
          entity_id:        tl.entity_id,
          vehicle_id:       tl.vehicle_id,
          link_type:        tl.link_type,
          url:              tl.url,
          tracking_url:     tl.tracking_url,
          created_at:       tl.created_at&.iso8601
        }
      end
    end
  end
end
