# frozen_string_literal: true

module Api
  module V1
    class SuppliersController < ApplicationController
      before_action :set_company_scope
      before_action :set_supplier, only: [:show, :update, :destroy, :parts]

      def index
        return unless authorize_action!('suppliers', 'read')

        suppliers = @company.suppliers.where(is_deleted: [false, nil])

        suppliers = suppliers.where(active: params[:active]) if params[:active].present?
        
        if params[:search].present?
          suppliers = suppliers.where(
            'name ILIKE ? OR code ILIKE ?', 
            "%#{params[:search]}%", 
            "%#{params[:search]}%"
          )
        end

        # Pagination
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        total_count = suppliers.count
        suppliers = suppliers.offset((page - 1) * per_page).limit(per_page)

        suppliers = suppliers.order(:name)

        render json: {
          items: suppliers.as_json(methods: [:display_name, :full_address]),
          meta: {
            total: total_count,
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      def show
        return unless authorize_action!('suppliers', 'read')

        render json: @supplier.as_json(
          methods: [:display_name, :full_address],
          include: {
            supplier_parts: {
              include: {
                part: { only: [:id, :sku, :name] }
              }
            }
          }
        )
      end

      def create
        return unless authorize_action!('suppliers', 'create')

        supplier = @company.suppliers.build(supplier_params)
        supplier.created_by = current_user

        if supplier.save
          render json: supplier, status: :created
        else
          render json: { errors: supplier.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        return unless authorize_action!('suppliers', 'update')

        @supplier.updated_by = current_user
        
        if @supplier.update(supplier_params)
          render json: @supplier
        else
          render json: { errors: @supplier.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        return unless authorize_action!('suppliers', 'delete')

        begin
          @supplier.soft_delete!
          render json: { message: 'Supplier deleted successfully' }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end

      def parts
        return unless authorize_action!('suppliers', 'read')

        supplier_parts = @supplier.parts.where(is_deleted: [false, nil])
        
        render json: supplier_parts.as_json(
          only: [:id, :sku, :name, :description, :active]
        )
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
          :tax_id, :notes, :payment_terms, :default_lead_time_days,
          :active
        )
      end
    end
  end
end
