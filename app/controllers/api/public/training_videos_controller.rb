# frozen_string_literal: true

module Api
  module Public
    # The watch page behind a training video's share link (E88). No sign-in;
    # the token is the only key, and turning sharing off ends the link.
    class TrainingVideosController < ApplicationController
      skip_before_action :authenticate

      def show
        video = shared.find_by(share_token: params[:token].to_s)
        return render(json: { error: 'This video link is not available' }, status: :not_found) unless video

        render json: { video: video.as_public_json.merge(token: video.share_token) }
      end

      # GET /api/public/training_videos/series/:module_key
      # Every shared video in an area, in order: "Watch all" as one course.
      def series
        videos = shared.where(module_key: params[:module_key].to_s).ordered.to_a
        return render(json: { error: 'This series is not available' }, status: :not_found) if videos.empty?

        render json: { module_key: params[:module_key], videos: videos.map { |v| v.as_public_json.merge(token: v.share_token) } }
      end

      # POST /api/public/training_videos/:token/play  (once per page view)
      def play
        TrainingVideo.where(share_token: params[:token].to_s, share_enabled: true).update_all('public_views = public_views + 1')
        head :no_content
      end

      private

      def shared
        TrainingVideo.where(share_enabled: true).where.not(video_url: [nil, ''])
      end
    end
  end
end
