# frozen_string_literal: true

module Api
  module V1
    class ReorderRulesController < ApplicationController
      before_action :set_company_scope
      before_action :set_rule, only: [:show, :update, :destroy]

      def index
        return unless authorize_action!('parts', 'read')

        rules = @company.reorder_rules.includes(:part, :location)

        # Filters
        rules = rules.where(part_id: params[:part_id]) if params[:part_id].present?
        rules = rules.where(location_id: params[:location_id]) if params[:location_id].present?
        rules = rules.where(active: params[:active]) if params[:active].present?

        # Location filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          rules = location_ids.any? ? rules.where(location_id: location_ids) : rules.none
        elsif Current.location_filtered?
          rules = rules.where(location_id: Current.location_id)
        end

        rules_data = rules.map do |rule|
          rule.as_json(
            methods: [:needs_reorder?, :current_stock, :suggested_order_quantity],
            include: {
              part: { only: [:id, :sku, :name] },
              location: { only: [:id, :name, :code] }
            }
          )
        end

        render json: rules_data
      end

      def show
        return unless authorize_action!('parts', 'read')

        render json: @rule.as_json(
          methods: [:needs_reorder?, :current_stock, :suggested_order_quantity],
          include: {
            part: { only: [:id, :sku, :name], methods: [:total_on_hand] },
            location: { only: [:id, :name, :code] }
          }
        )
      end

      def create
        return unless authorize_action!('parts', 'create')

        rule = @company.reorder_rules.build(rule_params)

        if rule.save
          render json: rule, status: :created
        else
          render json: { errors: rule.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        return unless authorize_action!('parts', 'update')

        if @rule.update(rule_params)
          render json: @rule
        else
          render json: { errors: @rule.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        return unless authorize_action!('parts', 'delete')

        @rule.destroy
        render json: { message: 'Reorder rule deleted successfully' }
      end

      def needs_reorder
        return unless authorize_action!('parts', 'read')

        rules = @company.reorder_rules.active.includes(:part, :location)

        # Location filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          rules = location_ids.any? ? rules.where(location_id: location_ids) : rules.none
        elsif Current.location_filtered?
          rules = rules.where(location_id: Current.location_id)
        end

        reorder_needed = rules.select(&:needs_reorder?)

        render json: reorder_needed.map { |rule|
          {
            rule: rule.as_json(
              only: [:id, :reorder_point, :reorder_quantity],
              methods: [:current_stock, :suggested_order_quantity]
            ),
            part: rule.part.as_json(only: [:id, :sku, :name]),
            location: rule.location.as_json(only: [:id, :name, :code]),
            shortage: rule.reorder_point - rule.current_stock
          }
        }
      end

      private

      def set_rule
        @rule = @company.reorder_rules.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Reorder rule not found' }, status: :not_found
      end

      def rule_params
        params.require(:reorder_rule).permit(
          :part_id, :location_id, :reorder_point,
          :reorder_quantity, :maximum_stock, :active
        )
      end
    end
  end
end
