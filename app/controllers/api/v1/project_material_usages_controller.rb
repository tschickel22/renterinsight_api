# frozen_string_literal: true

module Api
  module V1
    class ProjectMaterialUsagesController < ApplicationController
      before_action :set_company_scope
      before_action :set_project
      before_action :set_usage, only: %i[show check_out mark_used return_parts destroy]

      # GET /api/v1/projects/:project_id/materials
      def index
        return unless authorize_action!('projects', 'read')

        usages = @project.project_material_usages.not_deleted
                         .includes(:part, :location, :bin)

        # Filters
        usages = usages.for_phase(params[:phase_id])
        usages = usages.for_task(params[:task_id])
        usages = usages.by_status(params[:status])
        usages = usages.where(part_id: params[:part_id]) if params[:part_id].present?

        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
        allowed_sorts = %w[created_at status quantity_allocated]
        sort_by = 'created_at' unless allowed_sorts.include?(sort_by)
        usages = usages.order(sort_by => sort_order)

        total_count = usages.count
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        usages = usages.offset((page - 1) * per_page).limit(per_page)

        render json: {
          materials: usages.map { |u| material_json(u) },
          meta: { total_count: total_count, page: page, per_page: per_page }
        }
      end

      # GET /api/v1/projects/:project_id/materials/:id
      def show
        return unless authorize_action!('projects', 'read')
        render json: material_json(@usage)
      end

      # POST /api/v1/projects/:project_id/materials
      def create
        return unless authorize_action!('projects', 'update')

        @usage = @project.project_material_usages.build(usage_params)
        @usage.company_id = @company.id

        # Snapshot unit_cost from part
        if @usage.part_id.present?
          part = @company.parts.find_by(id: @usage.part_id)
          @usage.unit_cost ||= part&.default_cost if part
        end

        if @usage.save
          render json: material_json(@usage), status: :created
        else
          render json: { errors: @usage.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/projects/:project_id/materials/:id/check_out
      def check_out
        return unless authorize_action!('projects', 'update')

        @usage.check_out!(current_user, params[:quantity])
        render json: material_json(@usage.reload)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/projects/:project_id/materials/:id/mark_used
      def mark_used
        return unless authorize_action!('projects', 'update')

        unless params[:quantity_used].present?
          return render json: { error: 'quantity_used is required' }, status: :unprocessable_entity
        end

        @usage.mark_used!(current_user, params[:quantity_used])
        render json: material_json(@usage.reload)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/projects/:project_id/materials/:id/return_parts
      def return_parts
        return unless authorize_action!('projects', 'update')

        unless params[:quantity].present?
          return render json: { error: 'quantity is required' }, status: :unprocessable_entity
        end

        @usage.return_unused!(current_user, params[:quantity])
        render json: material_json(@usage.reload)
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/projects/:project_id/materials/:id
      def destroy
        return unless authorize_action!('projects', 'delete')

        if @usage.status == 'allocated'
          # Simple delete - no inventory to reverse
          @usage.update!(is_deleted: true)
        else
          # Has inventory transactions - do full reversal
          @usage.reverse!(current_user)
        end

        render json: { message: 'Material allocation removed and inventory restored' }
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # GET /api/v1/projects/:project_id/materials/search_parts
      def search_parts
        return unless authorize_action!('projects', 'read')

        parts = @company.parts.where(is_deleted: [false, nil])

        if params[:search].present?
          search_term = "%#{params[:search]}%"
          parts = parts.where(
            "name ILIKE ? OR sku ILIKE ? OR manufacturer_name ILIKE ?",
            search_term, search_term, search_term
          )
        end

        parts = parts.limit(25)

        render json: parts.map { |part|
          stock = part.stock_balances
          stock = stock.where(location_id: params[:location_id]) if params[:location_id].present?

          part.as_json(only: %i[id name sku manufacturer default_cost]).merge(
            stock_available: stock.sum(:available),
            stock_on_hand: stock.sum(:on_hand)
          )
        }
      end

      private

      def set_project
        @project = @company.projects.not_deleted.find(params[:project_id])
      end

      def set_usage
        @usage = @project.project_material_usages.not_deleted.find(params[:id])
      end

      def usage_params
        params.permit(
          :part_id, :location_id, :bin_id, :quantity_allocated,
          :project_phase_id, :project_task_id, :notes
        )
      end

      def material_json(usage)
        json = usage.as_json(
          only: %i[id project_id project_phase_id project_task_id part_id location_id
                   bin_id quantity_allocated quantity_checked_out quantity_used
                   quantity_returned unit_cost status checked_out_at used_at
                   returned_at notes created_at updated_at],
          methods: [:total_cost]
        )

        # Include part details
        if usage.part
          json['part'] = usage.part.as_json(only: %i[id name sku manufacturer default_cost])
          stock = usage.part.stock_balances.find_by(location_id: usage.location_id, bin_id: usage.bin_id)
          json['stock_available'] = stock&.available || 0
        end

        # Include location name
        json['location_name'] = usage.location&.name

        json
      end
    end
  end
end
