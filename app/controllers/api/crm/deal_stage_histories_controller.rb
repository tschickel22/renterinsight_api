module Api
  module Crm
    class DealStageHistoriesController < ApplicationController
      before_action :set_deal

      # GET /api/crm/deals/:deal_id/stage_histories
      def index
        histories = @deal.deal_stage_histories
                        .includes(:changed_by)
                        .order(created_at: :desc)
        
        render json: histories.map { |h| stage_history_json(h) }
      end

      # GET /api/crm/deals/:deal_id/stage_histories/:id
      def show
        history = @deal.deal_stage_histories.find(params[:id])
        render json: stage_history_json(history, detailed: true)
      end

      # POST /api/crm/deals/:deal_id/stage_histories
      def create
        history = @deal.deal_stage_histories.new(stage_history_params)
        history.changed_by_id = current_user_id
        
        if history.save
          # Update deal stage if needed
          if params[:update_deal_stage] == true || params[:update_deal_stage] == 'true'
            @deal.update(stage: history.stage)
          end
          
          render json: stage_history_json(history, detailed: true), status: :created
        else
          render json: { errors: history.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_deal
        @deal = Deal.find(params[:deal_id])
      end

      def stage_history_params
        params.require(:stage_history).permit(
          :stage, :previous_stage, :notes
        )
      end

      def current_user_id
        # This should be set by your authentication system
        current_user&.id
      end

      def stage_history_json(history, detailed: false)
        base = {
          id: history.id,
          dealId: history.deal_id,
          stage: history.stage,
          previousStage: history.previous_stage,
          changedById: history.changed_by_id,
          changedByName: history.changed_by&.name,
          duration: history.duration,
          notes: history.notes,
          createdAt: history.created_at&.iso8601
        }
        
        if detailed
          base.merge!(
            deal: {
              id: history.deal.id,
              name: history.deal.name,
              currentStage: history.deal.stage
            }
          )
        end
        
        base
      end
    end
  end
end
