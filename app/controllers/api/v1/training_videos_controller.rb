# frozen_string_literal: true

module Api
  module V1
    # The help center's Videos tab (E88). Dealers get published videos only
    # while the tab is switched on; a platform admin always gets every video
    # with a file, to preview what's coming.
    class TrainingVideosController < ApplicationController
      before_action :authenticate_user!

      def index
        admin = platform_admin_request?
        enabled = TrainingVideo.enabled?
        return render(json: { enabled: false, videos: [] }) unless enabled || admin

        scope = admin ? TrainingVideo.where.not(video_url: [nil, '']) : TrainingVideo.published
        render json: { enabled: enabled, preview: admin, videos: scope.ordered.map(&:as_api_json) }
      end

      private

      # Proxying as a dealer shows what the dealer sees.
      def platform_admin_request?
        admin = original_user
        (admin&.platform_admin? || admin&.super_admin?) && !impersonating?
      end
    end
  end
end
