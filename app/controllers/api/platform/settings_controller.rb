module Api
  module Platform
    class SettingsController < ApplicationController
      def show
        settings = PlatformSetting.instance
        render json: {
          communications: settings.communications || {}
        }
      end

      def update
        settings = PlatformSetting.instance
        settings.update!(communications: params[:communications] || settings.communications)
        render json: {
          communications: settings.communications
        }
      end
    end
  end
end

module Api
  module Company
    class SettingsController < ApplicationController
      def show
        # Get company from current_user or use first company for testing
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
