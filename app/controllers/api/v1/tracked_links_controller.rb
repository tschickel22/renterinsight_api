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

      private

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
          tracking_url:     tl.tracking_url,
          created_at:       tl.created_at&.iso8601
        }
      end
    end
  end
end
