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
