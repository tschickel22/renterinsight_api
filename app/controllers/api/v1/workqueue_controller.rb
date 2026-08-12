# frozen_string_literal: true

module Api
  module V1
    class WorkqueueController < ApplicationController
      before_action :set_company_scope

      # GET /api/v1/workqueue/summary
      def summary
        service = WorkqueueService.new(company: @company, user: current_user)
        render json: { groups: service.summary }
      end

      # GET /api/v1/workqueue/items?queue=leads_mine&page=1&per_page=50&search=...
      def items
        queue_id = params[:queue].to_s
        unless WorkqueueService::QUEUES.key?(queue_id)
          return render json: { error: "Unknown queue: #{queue_id}" }, status: :bad_request
        end

        service = WorkqueueService.new(
          company:  @company,
          user:     current_user,
          queue_id: queue_id,
          filters:  params.permit(:search, :sort_by, :sort_order).to_h.symbolize_keys,
          page:     params[:page] || 1,
          per_page: params[:per_page] || 50,
        )

        render json: service.items
      end

      # POST /api/v1/workqueue/dismiss
      #
      # "I have dealt with this one for now." Marks the record handled at this
      # moment, for this user only. Queues compare that moment against the
      # freshness of whatever put the row there, so a reply, a click or a new
      # task brings it back without the user having to undo anything.
      def dismiss
        entity_type = params[:entity_type].to_s.camelize
        entity_id = params[:entity_id].presence

        unless WorkqueueDismissal::ENTITY_TYPES.include?(entity_type)
          return render json: { error: "Unsupported entity type: #{params[:entity_type]}" },
                        status: :bad_request
        end

        return render json: { error: 'entity_id required' }, status: :bad_request if entity_id.blank?

        dismissal = WorkqueueDismissal.dismiss!(
          company: @company, user: current_user,
          entity_type: entity_type, entity_id: entity_id.to_i
        )

        render json: {
          entityType: dismissal.entity_type,
          entityId: dismissal.entity_id,
          dismissedAt: dismissal.dismissed_at.iso8601
        }, status: :created
      end

      # DELETE /api/v1/workqueue/dismiss — undo, for a row set aside by mistake.
      def undismiss
        WorkqueueDismissal.for_user(current_user)
                          .where(entity_type: params[:entity_type].to_s.camelize,
                                 entity_id: params[:entity_id].to_i)
                          .destroy_all

        head :no_content
      end
    end
  end
end
