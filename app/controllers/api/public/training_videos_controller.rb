# frozen_string_literal: true

module Api
  module Public
    # The watch page behind a training video's share link (E88). No sign-in;
    # the token is the only key, and turning sharing off ends the link.
    class TrainingVideosController < ApplicationController
      skip_before_action :authenticate

      def show
        video = TrainingVideo.find_by(share_token: params[:token].to_s, share_enabled: true)
        return render(json: { error: 'This video link is not available' }, status: :not_found) unless video&.video_url.present?

        render json: { video: video.as_public_json }
      end
    end
  end
end
