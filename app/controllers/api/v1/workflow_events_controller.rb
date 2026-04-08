module Api
  module V1
    class WorkflowEventsController < ApplicationController
      include RbacAuthorization
      before_action :set_company_scope
      rbac_resource :workflow_automation, read_actions: [:index]

      def index
        events = @company.workflow_events
        events = events.where(event_type: params[:event_type]) if params[:event_type].present?
        case params[:dispatched]
        when 'true'  then events = events.where.not(dispatched_at: nil)
        when 'false' then events = events.where(dispatched_at: nil)
        end
        events = events.where('created_at >= ?', params[:from]) if params[:from].present?
        events = events.where('created_at <= ?', params[:to]) if params[:to].present?
        events = events.order(created_at: :desc)

        filtered = events.count
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        events = events.offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: events.map { |e|
            {
              id: e.id,
              event_type: e.event_type,
              entity_type: e.entity_type,
              entity_id: e.entity_id,
              payload: e.payload,
              dispatched_at: e.dispatched_at,
              dispatch_error: e.dispatch_error,
              created_at: e.created_at
            }
          },
          meta: { total: filtered, page: page, per_page: per_page, total_pages: (filtered.to_f / per_page).ceil }
        }
      end
    end
  end
end
