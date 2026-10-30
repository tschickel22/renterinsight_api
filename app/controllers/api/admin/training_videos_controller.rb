# frozen_string_literal: true

module Api
  module Admin
    # Platform admin: training videos (E88). Files go through the server to
    # the public assets bucket, so nobody needs AWS keys to add a video.
    class TrainingVideosController < ApplicationController
      before_action :authenticate_user!
      before_action :require_platform_admin!
      before_action :set_video, only: %i[update destroy upload reset_share_link]

      UPLOADS = {
        'video' => { ext: %w[.mp4], types: %w[video/mp4] },
        'poster' => { ext: %w[.jpg .jpeg .png .webp], types: %w[image/jpeg image/png image/webp] },
        'captions' => { ext: %w[.vtt], types: %w[text/vtt] }
      }.freeze

      def index
        stats = TrainingVideoView.group(:training_video_id).pluck(:training_video_id, Arel.sql('COUNT(*)'), Arel.sql('COUNT(completed_at)'))
                                 .to_h { |id, viewers, done| [id, { viewers: viewers, completed: done }] }
        render json: {
          enabled: TrainingVideo.enabled?,
          videos: TrainingVideo.ordered.map { |v| v.as_api_json(admin: true).merge(stats: stats[v.id] || { viewers: 0, completed: 0 }) }
        }
      end

      def create
        video = TrainingVideo.new(video_params)
        return render(json: { video: video.as_api_json(admin: true) }, status: :created) if video.save

        render json: { error: video.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      def update
        return render(json: { video: @video.as_api_json(admin: true) }) if @video.update(video_params)

        render json: { error: @video.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      def destroy
        @video.destroy!
        head :no_content
      end

      # POST /api/admin/training_videos/:id/upload  kind=video|poster|captions, file
      def upload
        kind = params[:kind].to_s
        rule = UPLOADS[kind]
        file = params[:file]
        return render(json: { error: 'kind must be video, poster or captions' }, status: :unprocessable_entity) unless rule
        return render(json: { error: 'Attach a file' }, status: :unprocessable_entity) unless file.respond_to?(:original_filename)

        ext = File.extname(file.original_filename.to_s).downcase
        return render(json: { error: "A #{kind} must be #{rule[:ext].join(' or ')}" }, status: :unprocessable_entity) unless rule[:ext].include?(ext)

        # The browser's type for a .vtt is often blank or text/plain.
        upload_file = kind == 'captions' ? CaptionsFile.new(file) : file
        stored = S3UploadService.new.upload(upload_file, key: "training-videos/#{@video.slug}-#{Time.current.to_i}#{ext}")
        case kind
        when 'video' then @video.update!(video_url: stored[:url], video_key: stored[:key], video_size: stored[:size],
                                         duration_seconds: params[:duration_seconds].presence&.to_i || @video.duration_seconds)
        when 'poster' then @video.update!(poster_url: stored[:url])
        when 'captions'
          # The narration, so the help assistant can find what the video says.
          vtt = File.read(file.respond_to?(:tempfile) ? file.tempfile.path : file.path, encoding: 'UTF-8')
          @video.update!(captions_url: stored[:url], transcript: TrainingVideo.transcript_from_vtt(vtt))
        end
        render json: { video: @video.as_api_json(admin: true) }
      rescue RuntimeError => e
        render json: { error: e.message }, status: :bad_gateway
      end

      # The old link stops working.
      def reset_share_link
        @video.new_share_token!
        render json: { video: @video.as_api_json(admin: true) }
      end

      # PUT /api/admin/training_videos/settings  { enabled: true|false }
      def settings
        TrainingVideo.enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
        render json: { enabled: TrainingVideo.enabled? }
      end

      private

      def set_video
        @video = TrainingVideo.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def video_params
        params.require(:video).permit(:title, :slug, :description, :module_key, :position, :duration_seconds,
                                      :is_published, :share_enabled, chapters: %i[title start],
                                      covers: { routes: [], markers: [] })
      end

      # Wraps an upload so S3 stores captions as text/vtt.
      class CaptionsFile < SimpleDelegator
        def content_type = 'text/vtt'
      end
    end
  end
end
