# frozen_string_literal: true

module Api
  module V1
    class ProjectCostItemsController < ApplicationController
      before_action :set_company_scope
      before_action :set_project
      before_action :set_cost_item, only: %i[show update destroy]

      # GET /api/v1/projects/:project_id/cost_items
      def index
        return unless authorize_action!('projects', 'read')

        items = @project.project_cost_items.not_deleted

        # Stats BEFORE filtering (for dashboard tiles)
        stats = {
          total_cost: items.sum(:amount),
          by_type: items.group(:cost_type).sum(:amount),
          by_status: items.group(:status).sum(:amount),
          by_category: items.where.not(category: [nil, '']).group(:category).sum(:amount),
          budget_amount: @project.budget_amount,
          budget_remaining: @project.budget_variance,
          over_budget: @project.over_budget?
        }

        # Filters
        items = items.by_phase(params[:phase_id])
        items = items.by_task(params[:task_id])
        items = items.by_type(params[:cost_type])
        items = items.by_status(params[:status])
        items = items.by_date_range(params[:start_date], params[:end_date])

        if params[:search].present?
          search_term = "%#{params[:search]}%"
          items = items.where(
            "description ILIKE ? OR vendor_name ILIKE ? OR invoice_number ILIKE ?",
            search_term, search_term, search_term
          )
        end

        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order]&.downcase == 'asc' ? :asc : :desc
        allowed_sorts = %w[created_at date amount cost_type status vendor_name]
        sort_by = 'created_at' unless allowed_sorts.include?(sort_by)
        items = items.order(sort_by => sort_order)

        total_count = items.count
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        items = items.offset((page - 1) * per_page).limit(per_page)

        render json: {
          cost_items: items.includes(:contractor).map { |item|
            item.as_json(
              only: %i[id project_id project_phase_id project_task_id cost_type category
                       description vendor_name invoice_number amount quantity unit_price
                       date status paid_at approved_by_id notes receipt_url part_id
                       contractor_id inventory_transaction_id metadata created_at updated_at]
            ).merge('contractor_name' => item.contractor&.name)
          },
          stats: stats,
          meta: { total_count: total_count, page: page, per_page: per_page }
        }
      end

      # GET /api/v1/projects/:project_id/cost_items/:id
      def show
        return unless authorize_action!('projects', 'read')

        render json: @cost_item.as_json(
          only: %i[id project_id project_phase_id project_task_id cost_type category
                   description vendor_name invoice_number amount quantity unit_price
                   date status paid_at approved_by_id notes receipt_url receipt_s3_key
                   part_id inventory_transaction_id metadata created_at updated_at]
        )
      end

      # POST /api/v1/projects/:project_id/cost_items
      def create
        return unless authorize_action!('projects', 'update')

        @cost_item = @project.project_cost_items.build(cost_item_params)
        @cost_item.company_id = @company.id

        # Auto-populate vendor_name from contractor if provided
        if @cost_item.contractor_id.present? && @cost_item.vendor_name.blank?
          contractor = @company.contractors.find_by(id: @cost_item.contractor_id)
          @cost_item.vendor_name = contractor&.name
        end

        # Auto-populate from part if provided
        if @cost_item.part_id.present?
          part = @company.parts.find_by(id: @cost_item.part_id)
          if part
            @cost_item.unit_price ||= part.default_cost
            @cost_item.description = part.name if @cost_item.description.blank?
          end
        end

        if @cost_item.save
          render json: @cost_item.as_json(
            only: %i[id project_id project_phase_id project_task_id cost_type category
                     description vendor_name invoice_number amount quantity unit_price
                     date status paid_at approved_by_id notes receipt_url part_id
                     inventory_transaction_id metadata created_at updated_at]
          ), status: :created
        else
          render json: { errors: @cost_item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/projects/:project_id/cost_items/:id
      def update
        return unless authorize_action!('projects', 'update')

        if @cost_item.update(cost_item_params)
          render json: @cost_item.as_json(
            only: %i[id project_id project_phase_id project_task_id cost_type category
                     description vendor_name invoice_number amount quantity unit_price
                     date status paid_at approved_by_id notes receipt_url part_id
                     inventory_transaction_id metadata created_at updated_at]
          )
        else
          render json: { errors: @cost_item.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/projects/:project_id/cost_items/:id
      def destroy
        return unless authorize_action!('projects', 'delete')

        @cost_item.update!(is_deleted: true)
        @cost_item.project.recalculate_costs!
        @cost_item.project_phase&.recalculate_costs! if @cost_item.project_phase_id.present?

        render json: { message: 'Cost item deleted' }
      end

      # GET /api/v1/projects/:project_id/cost_items/summary
      def summary
        return unless authorize_action!('projects', 'read')

        items = @project.project_cost_items.not_deleted

        # Per-phase breakdown
        phases = @project.project_phases.map do |phase|
          phase_items = items.where(project_phase_id: phase.id)
          {
            id: phase.id,
            name: phase.name,
            estimated_budget: phase.estimated_budget,
            actual_cost: phase.actual_cost,
            variance: phase.estimated_budget ? (phase.estimated_budget - (phase.actual_cost || 0)) : nil,
            by_type: phase_items.group(:cost_type).sum(:amount)
          }
        end

        # Unassigned costs (no phase)
        unassigned = items.where(project_phase_id: nil)

        render json: {
          project: {
            budget_amount: @project.budget_amount,
            actual_cost: @project.actual_cost,
            labor_cost: @project.labor_cost,
            materials_cost: @project.materials_cost,
            subcontractor_cost: @project.subcontractor_cost,
            other_cost: @project.other_cost,
            variance: @project.budget_variance,
            variance_percentage: @project.budget_variance_percentage,
            over_budget: @project.over_budget?
          },
          phases: phases,
          unassigned: {
            total: unassigned.sum(:amount),
            by_type: unassigned.group(:cost_type).sum(:amount)
          },
          by_type: items.group(:cost_type).sum(:amount),
          by_status: items.group(:status).sum(:amount),
          by_category: items.where.not(category: [nil, '']).group(:category).sum(:amount)
        }
      end

      private

      def set_project
        @project = @company.projects.not_deleted.find(params[:project_id])
      end

      def set_cost_item
        @cost_item = @project.project_cost_items.not_deleted.find(params[:id])
      end

      def cost_item_params
        params.permit(
          :project_phase_id, :project_task_id, :cost_type, :category,
          :description, :vendor_name, :invoice_number, :amount, :quantity,
          :unit_price, :date, :status, :paid_at, :approved_by_id, :notes,
          :receipt_url, :receipt_s3_key, :part_id, :contractor_id, :inventory_transaction_id,
          metadata: {}
        )
      end
    end
  end
end
