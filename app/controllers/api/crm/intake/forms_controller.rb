module Api
  module Crm
    module Intake
      class FormsController < ApplicationController
        def index
          render json: IntakeForm.order(created_at: :desc).map { |f|
            {
              id: f.id,
              name: f.name,
              description: f.description,
              isActive: f.is_active,
              schema: f.schema,
              createdAt: f.created_at,
              updatedAt: f.updated_at,
            }
          }
        end

        # POST /api/crm/intake/forms/bulk
        def bulk
          permitted = params.permit!
          list = permitted.is_a?(Array) ? permitted : permitted[:forms]
          out = []
          IntakeForm.transaction do
            list.each do |attrs|
              f = if attrs[:id]
                    IntakeForm.find_by(id: attrs[:id]) || IntakeForm.new
                  else
                    IntakeForm.find_or_initialize_by(name: attrs[:name])
                  end
              f.name        = attrs[:name]
              f.description = attrs[:description]
              f.is_active   = attrs[:isActive]
              f.schema      = attrs[:schema]
              f.save!
              out << {
                id: f.id, name: f.name, description: f.description,
                isActive: f.is_active, schema: f.schema,
                createdAt: f.created_at, updatedAt: f.updated_at
              }
            end
          end
          render json: out
        end
      end
    end
  end
end
