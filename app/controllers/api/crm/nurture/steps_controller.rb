module Api
  module Crm
    module Nurture
      class StepsController < ApplicationController
        before_action :load_sequence

        # GET /api/crm/nurture/sequences/:sequence_id/steps
        def index
          render json: @sequence.steps.order(:position)
        end

        # POST /api/crm/nurture/sequences/:sequence_id/steps
        def create
          st = @sequence.steps.build(step_params)
          if st.save
            render json: st, status: :created
          else
            render json: { errors: st.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH/PUT /api/crm/nurture/sequences/:sequence_id/steps/:id
        def update
          st = @sequence.steps.find(params[:id])
          if st.update(step_params)
            render json: st
          else
            render json: { errors: st.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/crm/nurture/sequences/:sequence_id/steps/:id
        def destroy
          @sequence.steps.find(params[:id]).destroy
          head :no_content
        end

        private

        def load_sequence
          @sequence = NurtureSequence.find(params[:sequence_id])
        end

        def step_params
          params.require(:step).permit(:position, :step_type, :subject, :body, :wait_hours)
        end
      end
    end
  end
end
