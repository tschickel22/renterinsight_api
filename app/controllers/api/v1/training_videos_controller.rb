# frozen_string_literal: true

module Api
  module V1
    # The help center's Videos tab (E88). Dealers get published videos only
    # while the tab is switched on; a platform admin always gets every video
    # with a file, to preview what's coming. Each person's progress and the
    # videos their company requires of them come along.
    class TrainingVideosController < ApplicationController
      before_action :authenticate_user!

      def index
        admin = platform_admin_request?
        enabled = TrainingVideo.enabled?
        return render(json: { enabled: false, videos: [] }) unless enabled || admin

        videos = TrainingVideo.visible(admin: admin).ordered.to_a
        ids = videos.map(&:id)
        progress = TrainingVideoView.where(user_id: current_user.id, training_video_id: ids).index_by(&:training_video_id)
        assigned = TrainingAssignment.where(user_id: current_user.id, training_video_id: ids).index_by(&:training_video_id)
        render json: {
          enabled: enabled, preview: admin,
          videos: videos.map do |v|
            v.as_api_json.merge(progress: progress[v.id]&.as_progress_json,
                                assigned: assigned[v.id] && { due_on: assigned[v.id].due_on })
          end
        }
      end

      # POST /api/v1/training_videos/:id/progress  { position, seconds, started }
      def progress
        video = TrainingVideo.visible(admin: platform_admin_request?).find_by(id: params[:id])
        return render(json: { error: 'Not found' }, status: :not_found) unless video

        view = TrainingVideoView.record!(user: current_user, video: video, position: params[:position].to_f,
                                         seconds: params[:seconds].to_f, started: ActiveModel::Type::Boolean.new.cast(params[:started]))
        render json: { progress: view.as_progress_json }
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
