# frozen_string_literal: true

module Api
  module V1
    class BinsController < ApplicationController
      before_action :set_company_scope
      before_action :set_bin, only: [:show, :update, :destroy]

      def index
        return unless authorize_action!('bins', 'read')

        bins = Bin.joins(:location)
                  .where(locations: { company_id: @company.id })
                  .where(is_deleted: [false, nil])

        # Filter by location
        if params[:location_id].present?
          bins = bins.where(location_id: params[:location_id])
        elsif Current.location_filtered?
          bins = bins.where(location_id: Current.location_id)
        end

        bins = bins.where(active: params[:active]) if params[:active].present?
        bins = bins.where(bin_type: params[:bin_type]) if params[:bin_type].present?
        
        if params[:search].present?
          bins = bins.where('bin_code ILIKE ? OR label ILIKE ?', "%#{params[:search]}%", "%#{params[:search]}%")
        end

        bins = bins.order(:bin_code)

        # Eager load associations
        bins = bins.includes(:location, stock_balances: :part)
        
        Rails.logger.info "[BinsController#index] Found #{bins.count} bins"
        
        # Manually build JSON to avoid as_json re-querying
        result = bins.map do |bin|
          # Filter stock_balances to only show items with on_hand > 0
          filtered_stock_balances = bin.stock_balances.select { |sb| sb.on_hand.to_f > 0 }
          
          Rails.logger.info "[BinsController#index] Bin #{bin.bin_code}: #{bin.stock_balances.count} total, #{filtered_stock_balances.count} with stock"
          
          # Build JSON manually
          json = bin.as_json(only: [
            :id, :location_id, :bin_code, :label, :bin_type,
            :capacity_cubic_feet, :notes, :is_default, :active, :created_at, :updated_at
          ])
          
          # Add location
          json['location'] = bin.location.as_json(only: [:id, :name, :code])
          
          # Add filtered stock_balances with parts
          json['stock_balances'] = filtered_stock_balances.map do |sb|
            {
              id: sb.id,
              part_id: sb.part_id,
              on_hand: sb.on_hand,
              reserved: sb.reserved,
              available: sb.available,
              part: sb.part ? {
                id: sb.part.id,
                sku: sb.part.sku,
                name: sb.part.name
              } : nil
            }
          end
          
          json
        end
        
        render json: result
      end

      def show
        return unless authorize_action!('bins', 'read')

        # Eager load associations
        bin_with_stock = Bin.includes(stock_balances: :part).find(@bin.id)
        
        Rails.logger.info "[BinsController#show] Bin #{bin_with_stock.bin_code}: #{bin_with_stock.stock_balances.count} stock_balances loaded"
        
        # Filter stock_balances to only show items with on_hand > 0
        filtered_stock_balances = bin_with_stock.stock_balances.select { |sb| sb.on_hand.to_f > 0 }
        
        Rails.logger.info "[BinsController#show] Filtered to #{filtered_stock_balances.count} stock_balances with on_hand > 0"
        
        # Manually build JSON to avoid as_json re-querying
        json = bin_with_stock.as_json(only: [
          :id, :location_id, :bin_code, :label, :bin_type,
          :capacity_cubic_feet, :notes, :is_default, :active, :created_at, :updated_at
        ])
        
        # Add location
        json['location'] = bin_with_stock.location.as_json(only: [:id, :name, :code])
        
        # Add filtered stock_balances with parts
        json['stock_balances'] = filtered_stock_balances.map do |sb|
          {
            id: sb.id,
            part_id: sb.part_id,
            on_hand: sb.on_hand,
            reserved: sb.reserved,
            available: sb.available,
            part: sb.part ? {
              id: sb.part.id,
              sku: sb.part.sku,
              name: sb.part.name
            } : nil
          }
        end
        
        render json: json
      end

      def create
        return unless authorize_action!('bins', 'create')

        location = @company.locations.find(params[:bin][:location_id])
        bin = location.bins.build(bin_params)

        if bin.save
          render json: bin, status: :created
        else
          render json: { errors: bin.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        return unless authorize_action!('bins', 'update')

        if @bin.update(bin_params)
          render json: @bin
        else
          render json: { errors: @bin.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        return unless authorize_action!('bins', 'delete')

        begin
          @bin.soft_delete!
          render json: { message: 'Bin deleted successfully' }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end

      # Stats for all bins (location-filtered)
      def stats
        return unless authorize_action!('bins', 'read')

        bins = Bin.joins(:location)
                  .where(locations: { company_id: @company.id })
                  .where(is_deleted: [false, nil])

        # Apply location filter
        if params[:location_id].present?
          bins = bins.where(location_id: params[:location_id])
        elsif Current.location_filtered?
          bins = bins.where(location_id: Current.location_id)
        end

        # Get counts
        total_bins = bins.count
        active_bins = bins.where(active: true).count
        
        # Bins with stock (has stock_balances with on_hand > 0)
        bins_with_stock = bins.joins(:stock_balances)
                             .where('stock_balances.on_hand > 0')
                             .distinct
                             .count
        
        empty_bins = active_bins - bins_with_stock

        # Count by bin type
        by_type = bins.group(:bin_type).count

        render json: {
          total: total_bins,
          active: active_bins,
          with_stock: bins_with_stock,
          empty: empty_bins,
          inactive: total_bins - active_bins,
          by_type: by_type
        }
      end

      # Transfer inventory between bins
      def transfer
        return unless authorize_action!('bins', 'update')

        part_id = params[:part_id]
        from_bin_id = params[:from_bin_id]
        to_bin_id = params[:to_bin_id]
        quantity = params[:quantity].to_f
        notes = params[:notes]

        # Validate parameters
        if part_id.blank? || from_bin_id.blank? || to_bin_id.blank? || quantity <= 0
          return render json: { errors: ['Part, from bin, to bin, and quantity are required'] }, 
                       status: :unprocessable_entity
        end

        # Find bins and validate they belong to company
        from_bin = Bin.joins(:location).where(locations: { company_id: @company.id }).find(from_bin_id)
        to_bin = Bin.joins(:location).where(locations: { company_id: @company.id }).find(to_bin_id)
        part = @company.parts.find(part_id)

        # Validate bins are at same location
        if from_bin.location_id != to_bin.location_id
          return render json: { errors: ['Cannot transfer between different locations'] }, 
                       status: :unprocessable_entity
        end

        # Find source stock balance
        source_balance = StockBalance.find_by(
          company_id: @company.id,
          part_id: part_id,
          location_id: from_bin.location_id,
          bin_id: from_bin_id
        )

        unless source_balance && source_balance.available >= quantity
          return render json: { 
            errors: ["Insufficient available stock in bin #{from_bin.bin_code}. Available: #{source_balance&.available || 0}"] 
          }, status: :unprocessable_entity
        end

        ActiveRecord::Base.transaction do
          # Create transfer_out transaction
          transfer_out = InventoryTransaction.create!(
            company_id: @company.id,
            part_id: part_id,
            location_id: from_bin.location_id,
            bin_id: from_bin_id,
            transaction_type: 'transfer_out',
            quantity: -quantity,
            transaction_date: Time.current,
            notes: notes || "Transfer to bin #{to_bin.bin_code}",
            created_by: current_user
          )

          # Create transfer_in transaction
          transfer_in = InventoryTransaction.create!(
            company_id: @company.id,
            part_id: part_id,
            location_id: to_bin.location_id,
            bin_id: to_bin_id,
            transaction_type: 'transfer_in',
            quantity: quantity,
            source_transaction_id: transfer_out.id,
            transaction_date: Time.current,
            notes: notes || "Transfer from bin #{from_bin.bin_code}",
            created_by: current_user
          )

          render json: {
            message: "Successfully transferred #{quantity} units of #{part.name} from #{from_bin.bin_code} to #{to_bin.bin_code}",
            transfer_out: transfer_out.as_json,
            transfer_in: transfer_in.as_json
          }, status: :created
        end

      rescue ActiveRecord::RecordNotFound => e
        render json: { errors: [e.message] }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: [e.message] }, status: :unprocessable_entity
      rescue StandardError => e
        Rails.logger.error("Bin transfer error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: { errors: [e.message] }, status: :internal_server_error
      end

      private

      def set_bin
        @bin = Bin.joins(:location)
                  .where(locations: { company_id: @company.id })
                  .find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Bin not found' }, status: :not_found
      end

      def bin_params
        params.require(:bin).permit(
          :location_id, :bin_code, :label, :bin_type,
          :capacity_cubic_feet, :notes, :is_default, :active
        )
      end
    end
  end
end
