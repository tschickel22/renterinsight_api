module Api
  module V1
    class AgreementCategoriesController < ApplicationController
      before_action :set_company_scope
      before_action :set_category, only: [:update, :destroy]

      # GET /api/v1/agreement_categories
      def index
        return unless authorize_action!('agreements', 'read')

        categories = @company.agreement_categories.active.ordered

        # Include agreement counts per category
        agreement_counts = @company.agreements.active
          .where.not(category: nil)
          .group(:category)
          .count

        render json: {
          items: categories.map { |cat|
            category_json(cat).merge(agreement_count: agreement_counts[cat.name] || 0)
          }
        }
      rescue => e
        Rails.logger.error "Error in agreement_categories#index: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/agreement_categories
      def create
        return unless authorize_action!('agreements', 'create')

        category = @company.agreement_categories.new(category_params)

        if category.save
          render json: category_json(category), status: :created
        else
          render json: { errors: category.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/agreement_categories/:id
      def update
        return unless authorize_action!('agreements', 'update')

        if @category.is_system? && category_params[:name].present? && category_params[:name] != @category.name
          return render json: { error: 'Cannot rename system categories' }, status: :unprocessable_entity
        end

        if @category.update(category_params)
          render json: category_json(@category)
        else
          render json: { errors: @category.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/agreement_categories/:id
      def destroy
        return unless authorize_action!('agreements', 'delete')

        if @category.is_system?
          return render json: { error: 'Cannot delete system categories' }, status: :unprocessable_entity
        end

        active_count = @company.agreements.active.where(category: @category.name).count
        if active_count > 0
          return render json: { error: "Cannot delete category with #{active_count} active agreement(s)" }, status: :unprocessable_entity
        end

        @category.update!(is_deleted: true)
        head :no_content
      end

      private

      def set_company_scope
        unless current_user
          return render json: { error: 'Authentication required' }, status: :unauthorized
        end

        @company = Company.find_by(id: current_company_id)
        unless @company
          return render json: { error: 'Company not found' }, status: :not_found
        end
      end

      def set_category
        @category = @company.agreement_categories.active.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Category not found' }, status: :not_found
      end

      def category_params
        params.require(:agreement_category).permit(:name, :description, :color, :position)
      end

      def category_json(cat)
        {
          id: cat.id,
          name: cat.name,
          description: cat.description,
          color: cat.color,
          is_system: cat.is_system,
          position: cat.position,
          created_at: cat.created_at,
          updated_at: cat.updated_at
        }
      end
    end
  end
end
