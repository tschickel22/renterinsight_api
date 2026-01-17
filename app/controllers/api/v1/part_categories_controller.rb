# frozen_string_literal: true

module Api
  module V1
    class PartCategoriesController < ApplicationController
      before_action :set_company_scope
      before_action :set_category, only: [:show, :update, :destroy]

      def index
        return unless authorize_action!('inventory', 'read')

        categories = @company.part_categories.where(is_deleted: [false, nil])

        # Filter by parent (for building tree)
        if params[:parent_id].present?
          categories = categories.where(parent_id: params[:parent_id])
        elsif params[:top_level] == 'true'
          categories = categories.where(parent_id: nil)
        end

        categories = categories.where(active: params[:active]) if params[:active].present?
        categories = categories.order(:name)

        render json: categories.as_json(
          methods: [:full_path],
          include: {
            children: { only: [:id, :name] }
          }
        )
      end

      def show
        return unless authorize_action!('inventory', 'read')

        render json: @category.as_json(
          methods: [:full_path],
          include: {
            parent: { only: [:id, :name] },
            children: { only: [:id, :name] },
            parts: { only: [:id, :sku, :name] }
          }
        )
      end

      def create
        return unless authorize_action!('inventory', 'create')

        category = @company.part_categories.build(category_params)
        category.created_by = current_user

        if category.save
          render json: category, status: :created
        else
          render json: { errors: category.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        return unless authorize_action!('inventory', 'update')

        @category.updated_by = current_user
        
        if @category.update(category_params)
          render json: @category
        else
          render json: { errors: @category.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        return unless authorize_action!('inventory', 'delete')

        unless @category.can_delete?
          return render json: { 
            errors: ['Cannot delete category with parts or subcategories'] 
          }, status: :unprocessable_entity
        end

        @category.soft_delete!
        render json: { message: 'Category deleted successfully' }
      end

      def tree
        return unless authorize_action!('inventory', 'read')

        categories = @company.part_categories
                            .where(is_deleted: [false, nil], active: true)
                            .order(:name)

        # Build hierarchical tree
        tree = build_tree(categories.to_a, nil)

        render json: tree
      end

      private

      def set_category
        @category = @company.part_categories.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Category not found' }, status: :not_found
      end

      def category_params
        params.require(:part_category).permit(:name, :description, :parent_id, :active)
      end

      def build_tree(categories, parent_id)
        categories.select { |c| c.parent_id == parent_id }.map do |category|
          {
            id: category.id,
            name: category.name,
            description: category.description,
            active: category.active,
            children: build_tree(categories, category.id)
          }
        end
      end
    end
  end
end
