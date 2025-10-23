# frozen_string_literal: true

module Api
  module V1
    class LotMapLotsController < ApplicationController
      before_action :set_company
      before_action :set_layout
      before_action :set_lot, only: [:show, :update, :destroy, :assign, :unassign, :change_status, :history]
      
      # GET /api/v1/lot_map_layouts/:layout_id/lots
      def index
        @lots = @layout.lots.order(:number)
        
        # Optional filters
        @lots = @lots.by_status(params[:status]) if params[:status].present?
        @lots = @lots.by_area(params[:area]) if params[:area].present?
        
        render json: {
          lots: @lots.map do |lot|
            lot.as_json(except: [:created_at, :updated_at])
          end
        }
      end
      
      # GET /api/v1/lot_map_layouts/:layout_id/lots/:id
      def show
        render json: {
          lot: @lot.as_json(
            include: {
              history_entries: {
                only: [:id, :action, :inventory_id, :old_status, :new_status, :user_name, :details, :created_at],
                methods: [:timestamp]
              }
            }
          )
        }
      end
      
      # POST /api/v1/lot_map_layouts/:layout_id/lots
      def create
        @lot = @layout.lots.new(lot_params)
        
        if @lot.save
          # Log creation
          @lot.history_entries.create!(
            action: 'CREATED',
            new_status: @lot.status,
            user_id: current_user&.id,
            user_name: current_user&.email || 'system',
            details: "Lot #{@lot.number} created"
          )
          
          render json: {
            lot: @lot.as_json(except: [:created_at, :updated_at])
          }, status: :created
        else
          render json: { errors: @lot.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH/PUT /api/v1/lot_map_layouts/:layout_id/lots/:id
      def update
        if @lot.update(lot_params)
          render json: {
            lot: @lot.as_json(except: [:created_at, :updated_at])
          }
        else
          render json: { errors: @lot.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/lot_map_layouts/:layout_id/lots/:id
      def destroy
        @lot.destroy
        head :no_content
      end
      
      # POST /api/v1/lot_map_layouts/:layout_id/lots/:id/assign
      def assign
        inventory_id = params[:inventory_id]
        inventory_info = params[:inventory_info] || "Inventory ##{inventory_id}"
        
        begin
          @lot.assign_inventory!(
            inventory_id,
            inventory_info,
            user_id: current_user&.id,
            user_name: current_user&.email || 'system'
          )
          
          render json: {
            lot: @lot.reload.as_json(except: [:created_at, :updated_at]),
            message: 'Vehicle assigned successfully'
          }
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/lot_map_layouts/:layout_id/lots/:id/unassign
      def unassign
        begin
          @lot.unassign_inventory!(
            user_id: current_user&.id,
            user_name: current_user&.email || 'system'
          )
          
          render json: {
            lot: @lot.reload.as_json(except: [:created_at, :updated_at]),
            message: 'Vehicle unassigned successfully'
          }
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/lot_map_layouts/:layout_id/lots/:id/change_status
      def change_status
        new_status = params[:status]
        
        unless valid_status?(new_status)
          return render json: { error: 'Invalid status' }, status: :unprocessable_entity
        end
        
        begin
          @lot.change_status!(
            new_status,
            user_id: current_user&.id,
            user_name: current_user&.email || 'system'
          )
          
          render json: {
            lot: @lot.reload.as_json(except: [:created_at, :updated_at]),
            message: 'Status changed successfully'
          }
        rescue => e
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end
      
      # GET /api/v1/lot_map_layouts/:layout_id/lots/:id/history
      def history
        @history = @lot.history_entries.recent.limit(50)
        
        render json: {
          history: @history.map do |entry|
            entry.as_json(
              only: [:id, :action, :inventory_id, :old_status, :new_status, :user_name, :details],
              methods: [:timestamp]
            )
          end
        }
      end
      
      private
      
      def set_company
        @company = current_user&.company || Company.first
      end
      
      def set_layout
        @layout = @company.lot_map_layouts.find(params[:layout_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Layout not found' }, status: :not_found
      end
      
      def set_lot
        @lot = @layout.lots.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Lot not found' }, status: :not_found
      end
      
      def lot_params
        params.require(:lot).permit(
          :number,
          :position,
          :status,
          :assigned_inventory_id,
          :assigned_inventory_info,
          :area,
          :notes
        )
      end
      
      def valid_status?(status)
        %w[empty available sold_pending reserved service display new_arrival wholesale in_transit maintenance].include?(status)
      end
    end
  end
end
