# frozen_string_literal: true

module Api
  module Crm
    module Nurture
      class EnrollmentsController < ApplicationController
        def index
          enrollments = NurtureEnrollment.includes(:lead, :nurture_sequence).order(created_at: :desc)
          render json: enrollments.map { |e| enrollment_json(e) }, status: :ok
        end

        def create
          enrollment = NurtureEnrollment.new(enrollment_params)
          if enrollment.save
            render json: enrollment_json(enrollment), status: :created
          else
            render json: { errors: enrollment.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          enrollment = NurtureEnrollment.find(params[:id])
          if enrollment.update(enrollment_params)
            render json: enrollment_json(enrollment), status: :ok
          else
            render json: { errors: enrollment.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          enrollment = NurtureEnrollment.find(params[:id])
          enrollment.destroy!
          head :no_content
        end

        def bulk
          enrollments = params[:_json] || params[:enrollments] || []
          result = enrollments.map do |enr_data|
            if enr_data[:id]
              enrollment = NurtureEnrollment.find(enr_data[:id])
              enrollment.update!(enrollment_params_from_hash(enr_data))
            else
              enrollment = NurtureEnrollment.create!(enrollment_params_from_hash(enr_data))
            end
            enrollment_json(enrollment)
          end
          render json: result, status: :ok
        end

        private

        def enrollment_params
          params.require(:enrollment).permit(:lead_id, :nurture_sequence_id, :status, :current_step_index)
        end

        def enrollment_params_from_hash(hash)
          {
            lead_id: hash[:leadId] || hash[:lead_id],
            nurture_sequence_id: hash[:sequenceId] || hash[:nurture_sequence_id],
            status: hash[:status],
            current_step_index: hash[:currentStepIndex] || hash[:current_step_index]
          }.compact
        end

        def enrollment_json(enrollment)
          {
            id: enrollment.id,
            leadId: enrollment.lead_id,
            sequenceId: enrollment.nurture_sequence_id,
            status: enrollment.status,
            currentStepIndex: enrollment.current_step_index,
            createdAt: enrollment.created_at&.iso8601,
            updatedAt: enrollment.updated_at&.iso8601
          }
        end
      end
    end
  end
end
