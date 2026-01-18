# frozen_string_literal: true

module Api
  module V1
    class InventoryTransactionsController < ApplicationController
      before_action :set_company_scope

      def index
        return unless authorize_action!('parts', 'read')

        transactions = @company.inventory_transactions.includes(:part, :location, :bin, :created_by)

        # Filters
        transactions = transactions.where(part_id: params[:part_id]) if params[:part_id].present?
        transactions = transactions.where(location_id: params[:location_id]) if params[:location_id].present?
        transactions = transactions.where(transaction_type: params[:transaction_type]) if params[:transaction_type].present?
        
        if params[:start_date].present? && params[:end_date].present?
          transactions = transactions.where(transaction_date: params[:start_date]..params[:end_date])
        end

        # Location filtering for non-admins
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          transactions = location_ids.any? ? transactions.where(location_id: location_ids) : transactions.none
        end

        # Pagination
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 50).to_i, 200].min
        total_count = transactions.count
        transactions = transactions.recent.offset((page - 1) * per_page).limit(per_page)

        render json: {
          items: transactions,
          meta: {
            total: total_count,
            page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil
          }
        }
      end

      def show
        return unless authorize_action!('parts', 'read')

        transaction = @company.inventory_transactions.find(params[:id])

        render json: transaction.as_json(
          methods: [:display_type, :total_value, :is_transfer?],
          include: {
            part: { only: [:id, :sku, :name] },
            location: { only: [:id, :name, :code] },
            bin: { only: [:id, :bin_code, :label] },
            created_by: { only: [:id, :first_name, :last_name] }
          }
        )
      end

      def receive
        return unless authorize_action!('parts', 'create')

        service = InventoryTransactionService.new(@company, current_user)
        transaction = service.receive(receive_params.to_h)

        if transaction
          render json: transaction, status: :created
        else
          render json: { errors: ['Failed to create receive transaction'] }, status: :unprocessable_entity
        end
      end

      def transfer
        return unless authorize_action!('parts', 'update')

        service = InventoryTransactionService.new(@company, current_user)
        result = service.transfer(transfer_params.to_h)

        if result
          render json: {
            transfer_out: result[:transfer_out],
            transfer_in: result[:transfer_in],
            message: 'Transfer completed successfully'
          }, status: :created
        else
          render json: { errors: ['Failed to create transfer'] }, status: :unprocessable_entity
        end
      end

      def adjust
        return unless authorize_action!('parts', 'update')

        service = InventoryTransactionService.new(@company, current_user)
        transaction = service.adjust(adjust_params.to_h)

        if transaction
          render json: transaction, status: :created
        else
          Rails.logger.error("[InventoryTransactions#adjust] Errors: #{service.errors.inspect}")
          render json: { errors: service.errors.presence || ['Failed to create adjustment'] }, status: :unprocessable_entity
        end
      end

      def consume
        return unless authorize_action!('parts', 'update')

        service = InventoryTransactionService.new(@company, current_user)
        transaction = service.consume(consume_params.to_h)

        if transaction
          render json: transaction, status: :created
        else
          render json: { errors: ['Failed to create consumption transaction'] }, status: :unprocessable_entity
        end
      end

      def return_inventory
        return unless authorize_action!('parts', 'update')

        service = InventoryTransactionService.new(@company, current_user)
        transaction = service.return_inventory(return_params.to_h)

        if transaction
          render json: transaction, status: :created
        else
          render json: { errors: ['Failed to create return transaction'] }, status: :unprocessable_entity
        end
      end

      private

      def receive_params
        params.require(:transaction).permit(
          :part_id, :location_id, :bin_id, :quantity, :unit_cost,
          :serial_number, :lot_number, :lot_expiration_date,
          :purchase_order_line_id, :notes, :transaction_date
        )
      end

      def transfer_params
        params.require(:transaction).permit(
          :part_id, :from_location_id, :from_bin_id,
          :to_location_id, :to_bin_id, :quantity,
          :serial_number, :lot_number, :lot_expiration_date,
          :notes, :transaction_date
        )
      end

      def adjust_params
        params.require(:transaction).permit(
          :part_id, :location_id, :bin_id, :quantity, :unit_cost,
          :serial_number, :lot_number, :notes, :transaction_date
        )
      end

      def consume_params
        params.require(:transaction).permit(
          :part_id, :location_id, :bin_id, :quantity,
          :job_id, :reference_type, :reference_id,
          :serial_number, :lot_number, :notes, :transaction_date
        )
      end

      def return_params
        params.require(:transaction).permit(
          :part_id, :location_id, :bin_id, :quantity, :unit_cost,
          :job_id, :reference_type, :reference_id,
          :serial_number, :lot_number, :notes, :transaction_date
        )
      end
    end
  end
end
