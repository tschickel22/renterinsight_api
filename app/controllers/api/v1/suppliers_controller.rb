# frozen_string_literal: true

module Api
  module V1
    class SuppliersController < ApplicationController
      before_action :set_company_scope
      before_action :set_supplier, only: [:show, :update, :destroy, :parts]

      def index
        return unless authorize_action!('inventory', 'read')

        suppliers = @company.suppliers.where(is_deleted: [false, nil])

        # Filters
        suppliers = suppliers.where(active: params[:active]) if params[:active].present?
        
        # Filter suppliers with parts - show suppliers where we have inventory on hand
        if params[:with_parts].present? && params[:with_parts] == 'true'
          suppliers = suppliers.joins(parts: :stock_balances)
                              .where('stock_balances.on_hand > 0')
                              .where('parts.is_deleted = ? OR parts.is_deleted IS NULL', false)
                              .distinct
        end
        
        if params[:search].present?
          suppliers = suppliers.where(
            'name ILIKE ? OR code ILIKE ? OR contact_name ILIKE ?',
            "%#{params[:search]}%", "%#{params[:search]}%", "%#{params[:search]}%"
          )
        end

        # Pagination
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        total_count = suppliers.count
        suppliers = suppliers.by_name.offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: suppliers,
          meta: {
            total: total_count,
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      def show
        return unless authorize_action!('inventory', 'read')

        render json: @supplier.as_json(
          include: {
            parts: { 
              only: [:id, :sku, :name],
              methods: [:total_on_hand]
            }
          }
        )
      end

      def create
        return unless authorize_action!('inventory', 'create')

        supplier = @company.suppliers.build(supplier_params)
        supplier.created_by = current_user

        if supplier.save
          render json: supplier, status: :created
        else
          render json: { errors: supplier.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        return unless authorize_action!('inventory', 'update')

        @supplier.updated_by = current_user
        
        if @supplier.update(supplier_params)
          render json: @supplier
        else
          render json: { errors: @supplier.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        return unless authorize_action!('inventory', 'delete')

        if @supplier.parts.exists?
          render json: { 
            errors: ['Cannot delete supplier with linked parts. Remove part associations first.'] 
          }, status: :unprocessable_entity
          return
        end

        begin
          @supplier.soft_delete!
          render json: { message: 'Supplier deleted successfully' }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end

      def parts
        return unless authorize_action!('inventory', 'read')

        parts = @supplier.parts.where(is_deleted: [false, nil])
        
        render json: parts.as_json(
          only: [:id, :sku, :name, :uom],
          methods: [:total_on_hand, :total_available]
        )
      end

      def stats
        return unless authorize_action!('inventory', 'read')

        suppliers = @company.suppliers.where(is_deleted: [false, nil])

        # Count suppliers where we have actual inventory on hand from them
        suppliers_with_stock = suppliers.joins(parts: :stock_balances)
                                       .where('stock_balances.on_hand > 0')
                                       .where('parts.is_deleted = ? OR parts.is_deleted IS NULL', false)
                                       .distinct
                                       .count

        render json: {
          total_suppliers: suppliers.count,
          active_suppliers: suppliers.where(active: true).count,
          suppliers_with_parts: suppliers_with_stock
        }
      end

      private

      def set_supplier
        @supplier = @company.suppliers.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Supplier not found' }, status: :not_found
      end

      def supplier_params
        params.require(:supplier).permit(
          :name, :code, :contact_name, :email, :phone, :website,
          :address_line1, :address_line2, :city, :state, :zip_code, :country,
          :payment_terms, :default_lead_time_days, :tax_id, :notes,
          :active
        )
        # Note: company_id NOT permitted (tenant isolation)
      end
    end
  end
end
