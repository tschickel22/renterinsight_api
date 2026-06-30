# frozen_string_literal: true
# Tenant-configurable lead status list. Each company manages its own set via
# the Lead Statuses tab in CRM settings. Backs the status dropdown on the
# lead form and the status filter on the lead list.

module Api
  module Crm
    class LeadStatusesController < ApplicationController
      before_action :set_company_scope
      before_action :set_lead_status, only: %i[update destroy]

      # GET /api/crm/lead_statuses
      def index
        return unless authorize_action!('leads', 'read')

        statuses = @company.lead_statuses.ordered
        statuses = statuses.active unless params[:include_inactive] == 'true'
        render json: statuses.map { |s| status_json(s) }
      end

      # POST /api/crm/lead_statuses
      def create
        return unless authorize_action!('leads', 'update')

        status = @company.lead_statuses.build(lead_status_params)
        if status.save
          render json: status_json(status), status: :created
        else
          render json: { errors: status.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/crm/lead_statuses/:id
      def update
        return unless authorize_action!('leads', 'update')

        if @lead_status.update(lead_status_params)
          render json: status_json(@lead_status)
        else
          render json: { errors: @lead_status.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/crm/lead_statuses/:id
      # Soft delete: if any leads currently use this status, set is_active=false
      # so it disappears from new dropdowns but the existing leads still resolve
      # the label. Hard-delete only if nothing references it.
      def destroy
        return unless authorize_action!('leads', 'update')

        in_use = @company.leads.where(status: @lead_status.key).exists?
        if in_use
          @lead_status.update!(is_active: false)
          render json: { soft_deleted: true, status: status_json(@lead_status) }
        else
          @lead_status.destroy!
          head :no_content
        end
      end

      # POST /api/crm/lead_statuses/reorder
      # Body: { ordered_ids: [3, 1, 2, ...] } — rewrites sort_order in 10s.
      def reorder
        return unless authorize_action!('leads', 'update')

        ids = Array(params[:ordered_ids]).map(&:to_i)
        @company.lead_statuses.where(id: ids).find_each do |status|
          status.update_column(:sort_order, (ids.index(status.id) + 1) * 10)
        end
        render json: { ok: true }
      end

      private

      def set_lead_status
        @lead_status = @company.lead_statuses.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def lead_status_params
        params.require(:lead_status).permit(:key, :label, :color, :sort_order, :is_active, :is_excluded)
      end

      def status_json(s)
        {
          id: s.id,
          key: s.key,
          label: s.label,
          color: s.color,
          sort_order: s.sort_order,
          is_active: s.is_active,
          is_excluded: s.is_excluded,
          created_at: s.created_at,
          updated_at: s.updated_at,
        }
      end
    end
  end
end
