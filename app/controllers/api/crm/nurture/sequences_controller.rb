# frozen_string_literal: true

module Api
  module Crm
    module Nurture
      class SequencesController < ApplicationController
        def index
          sequences = NurtureSequence.all.order(created_at: :desc)
          render json: sequences.map { |s| sequence_json(s) }, status: :ok
        end

        def create
          sequence = NurtureSequence.new(sequence_params)
          if sequence.save
            render json: sequence_json(sequence), status: :created
          else
            render json: { errors: sequence.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          sequence = NurtureSequence.find(params[:id])
          if sequence.update(sequence_params)
            render json: sequence_json(sequence), status: :ok
          else
            render json: { errors: sequence.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          sequence = NurtureSequence.find(params[:id])
          sequence.destroy!
          head :no_content
        end

        def bulk
          sequences = params[:_json] || params[:sequences] || []
          result = sequences.map do |seq_data|
            if seq_data[:id]
              sequence = NurtureSequence.find(seq_data[:id])
              sequence.update!(seq_data.except(:id, :steps))
            else
              sequence = NurtureSequence.create!(seq_data.except(:steps))
            end
            sequence_json(sequence)
          end
          render json: result, status: :ok
        end

        private

        def sequence_params
          params.require(:sequence).permit(:name, :description, :is_active)
        end

        def sequence_json(sequence)
          {
            id: sequence.id,
            name: sequence.name,
            description: sequence.description,
            isActive: sequence.is_active,
            steps: sequence.nurture_steps.order(:position).map { |s| step_json(s) },
            createdAt: sequence.created_at&.iso8601,
            updatedAt: sequence.updated_at&.iso8601
          }
        end

        def step_json(step)
          {
            id: step.id,
            type: step.step_type,
            subject: step.subject,
            body: step.body,
            waitDays: step.wait_days,
            position: step.position,
            templateId: step.template_id
          }
        end
      end
    end
  end
end
