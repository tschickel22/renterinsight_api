module Api
  module Company
    class SettingsController < ApplicationController
      def show
        company = current_user&.company || Company.first
        
        render json: {
          communications: company&.communications_settings || {}
        }
      end

      def update
        company = current_user&.company || Company.first
        
        if company
          company.update!(communications_settings: params[:communications] || company.communications_settings)
          render json: {
            communications: company.communications_settings
          }
        else
          render json: { error: 'No company found' }, status: :not_found
        end
      end
    end
  end
end
