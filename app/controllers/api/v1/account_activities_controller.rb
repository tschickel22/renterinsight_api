module Api
  module V1
    class AccountActivitiesController < ApplicationController
      before_action :set_account
      before_action :set_activity, only: [:show, :update, :destroy]

      # GET /api/v1/accounts/:account_id/activities
      def index
        @activities = @account.activities.order(created_at: :desc)
        
        render json: {
          activities: @activities.map do |activity|
            {
              id: activity.id,
              accountId: activity.account_id,
              type: activity.activity_type,
              description: activity.description,
              outcome: activity.outcome,
              duration: activity.duration,
              scheduledDate: activity.scheduled_date,
              userId: activity.user_id,
              createdAt: activity.created_at,
              updatedAt: activity.updated_at
            }
          end
        }
      end

      # GET /api/v1/accounts/:account_id/activities/:id
      def show
        render json: activity_json(@activity)
      end

      # POST /api/v1/accounts/:account_id/activities
      def create
        @activity = @account.activities.build(activity_params)
        @activity.user_id ||= current_user&.id

        if @activity.save
          render json: activity_json(@activity), status: :created
        else
          render json: { errors: @activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/accounts/:account_id/activities/:id
      def update
        if @activity.update(activity_params)
          render json: activity_json(@activity)
        else
          render json: { errors: @activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/accounts/:account_id/activities/:id
      def destroy
        @activity.destroy
        head :no_content
      end

      private

      def set_account
        @account = Account.find(params[:account_id])
      end

      def set_activity
        @activity = @account.activities.find(params[:id])
      end

      def activity_params
        params.require(:activity).permit(
          :activity_type, 
          :description, 
          :outcome, 
          :duration, 
          :scheduled_date
        )
      end

      def activity_json(activity)
        {
          id: activity.id,
          accountId: activity.account_id,
          type: activity.activity_type,
          description: activity.description,
          outcome: activity.outcome,
          duration: activity.duration,
          scheduledDate: activity.scheduled_date,
          userId: activity.user_id,
          createdAt: activity.created_at,
          updatedAt: activity.updated_at
        }
      end

      def current_user
        # This should be implemented based on your authentication system
        User.first
      end
    end
  end
end
