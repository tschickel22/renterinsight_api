module Api
  module Crm
    module Intake
      class SubmissionsController < ApplicationController
        def index
          render json: IntakeSubmission.order(created_at: :desc).limit(200).map { |s|
            {
              id: s.id,
              formId: s.intake_form_id,
              leadId: s.lead_id,
              payload: s.payload,
              createdAt: s.created_at,
              updatedAt: s.updated_at
            }
          }
        end

        # POST /api/crm/intake/submissions/bulk
        def bulk
          permitted = params.permit!
          list = permitted.is_a?(Array) ? permitted : permitted[:submissions]
          out = []
          IntakeSubmission.transaction do
            list.each do |attrs|
              s = IntakeSubmission.new
              s.intake_form_id = attrs[:formId] || attrs[:intakeFormId]
              s.lead_id        = attrs[:leadId]
              s.payload        = attrs[:payload] || {}
              s.save!
              out << {
                id: s.id, formId: s.intake_form_id, leadId: s.lead_id,
                payload: s.payload, createdAt: s.created_at, updatedAt: s.updated_at
              }
            end
          end
          render json: out
        end
      end
    end
  end
end
