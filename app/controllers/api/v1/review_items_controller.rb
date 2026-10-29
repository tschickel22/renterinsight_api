# frozen_string_literal: true

module Api
  module V1
    # Review Updates (E87): project work waiting on someone in this company.
    # Items open and close from ProjectNotices as the work happens; the only
    # thing done here is marking an FYI item seen (or reopening it).
    class ReviewItemsController < ApplicationController
      before_action :set_company_scope
      before_action :set_item, only: %i[seen reopen]

      # GET /api/v1/review_items?status=open|closed&scope=mine|all&kind=&project_id=&page=
      def index
        return unless authorize_action!('deals', 'read')

        items = visible_items
        items = items.where(status: params[:status] == 'closed' ? 'closed' : 'open')
        items = items.for_user(current_user) if params[:scope] == 'mine'
        items = items.where(kind: params[:kind]) if params[:kind].present?
        items = items.where(project_id: params[:project_id]) if params[:project_id].present?
        items = items.where(needs_action: ActiveModel::Type::Boolean.new.cast(params[:needs_action])) if params.key?(:needs_action)

        total = items.count
        page = [(params[:page] || 1).to_i, 1].max
        per_page = [(params[:per_page] || 50).to_i, 200].min
        order = params[:status] == 'closed' ? { resolved_at: :desc } : { needs_action: :desc, updated_at: :desc }
        rows = items.includes(:project, :project_phase).order(order).offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: rows.map(&:as_api_json),
          kinds: ReviewItem::KINDS.map { |k, (label, action)| { key: k, label: label, needsAction: action } },
          meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil,
                  counts: counts_json }
        }
      end

      # GET /api/v1/review_items/counts (menu badge and dashboard card)
      def counts
        return unless authorize_action!('deals', 'read')

        render json: counts_json
      end

      # POST /api/v1/review_items/:id/seen
      def seen
        return unless authorize_action!('deals', 'read')

        @item.update!(status: 'closed', resolution: @item.needs_action ? 'dismissed' : 'seen',
                      resolved_at: Time.current, resolved_by_id: current_user.id,
                      resolved_by_name: current_user.full_name.presence || current_user.email)
        render json: { item: @item.as_api_json, counts: counts_json }
      end

      # POST /api/v1/review_items/:id/reopen (an FYI item marked seen by mistake)
      def reopen
        return unless authorize_action!('deals', 'read')
        return render(json: { error: 'Only items someone marked seen can be reopened' }, status: :unprocessable_entity) unless @item.resolution.in?(%w[seen dismissed])
        if visible_items.open.where(kind: @item.kind, subject_type: @item.subject_type, subject_id: @item.subject_id).exists?
          return render(json: { error: 'This is already open again' }, status: :unprocessable_entity)
        end

        @item.update!(status: 'open', resolution: nil, resolved_at: nil, resolved_by_id: nil, resolved_by_name: nil)
        render json: { item: @item.as_api_json, counts: counts_json }
      end

      private

      def set_item
        @item = visible_items.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      # Project items follow the project's location rules; items with no
      # project (a link request, a rate card) are company-wide.
      def visible_items
        items = @company.review_items
        if current_user.uses_rbac? && !current_user.effective_admin?
          ids = permission_service.accessible_location_ids
          items = items.left_joins(:project).where(project_id: nil).or(
            items.left_joins(:project).where(projects: { location_id: ids })
          )
        end
        if Current.location_filtered?
          items = items.left_joins(:project).where(project_id: nil).or(
            items.left_joins(:project).where(projects: { location_id: [Current.location_id, nil] })
          )
        end
        items
      end

      def counts_json
        open = visible_items.open
        {
          mine: open.actionable.for_user(current_user).count,
          all: open.actionable.count,
          mineFyi: open.where(needs_action: false).for_user(current_user).count,
          allOpen: open.count
        }
      end
    end
  end
end
