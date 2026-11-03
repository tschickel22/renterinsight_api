# frozen_string_literal: true

module Api
  module Public
    # The training pipeline sends finished videos here for review (E91). All it
    # can do is make or replace an unpublished draft with sharing off: it cannot
    # publish, share, delete or touch a published video. It answers only where
    # the key's digest is stored in Settings, which is staging, and never on a
    # server that copies its help from another one, which is production.
    class TrainingVideoDraftsController < ApplicationController
      skip_before_action :authenticate
      before_action :require_upload_key
      before_action :set_draft, only: :file

      TOKEN_DIGEST_KEY = 'training_upload_token_sha256'
      FILES = { 'video' => %w[.mp4], 'poster' => %w[.jpg .jpeg .png .webp], 'captions' => %w[.vtt] }.freeze

      # PUT /api/public/training_video_drafts/:slug
      def upsert
        video = TrainingVideo.find_or_initialize_by(slug: params[:slug].to_s)
        return refuse_published if video.is_published

        video.assign_attributes(draft_params.merge(is_published: false, share_enabled: false))
        video.save!
        render json: { id: video.id, slug: video.slug, uid: video.uid, is_published: false, share_enabled: false }
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/public/training_video_drafts/:slug/files  kind=video|poster|captions, file
      def file
        return refuse_published if @video.is_published

        kind = params[:kind].to_s
        upload = params[:file]
        return render(json: { error: 'kind must be video, poster or captions' }, status: :unprocessable_entity) unless FILES.key?(kind)
        return render(json: { error: 'Attach a file' }, status: :unprocessable_entity) unless upload.respond_to?(:original_filename)
        unless FILES[kind].include?(File.extname(upload.original_filename.to_s).downcase)
          return render(json: { error: "A #{kind} must be #{FILES[kind].join(' or ')}" }, status: :unprocessable_entity)
        end

        @video.attach_file!(kind, upload, duration_seconds: params[:duration_seconds])
        render json: { slug: @video.slug, kind: kind, uploaded: true }
      rescue RuntimeError => e
        render json: { error: e.message }, status: :bad_gateway
      end

      private

      def require_upload_key
        digest = Setting.get('Platform', PlatformSetting::PLATFORM_SCOPE_ID, TOKEN_DIGEST_KEY).to_s
        given = Digest::SHA256.hexdigest(request.headers['X-Training-Upload-Key'].to_s)
        allowed = ENV['GUIDE_SYNC_SOURCE_URL'].blank? && digest.present? &&
                  ActiveSupport::SecurityUtils.secure_compare(digest, given)
        render json: { error: 'not allowed' }, status: :unauthorized unless allowed
      end

      def set_draft
        @video = TrainingVideo.find_by(slug: params[:slug].to_s)
        render json: { error: 'No such draft' }, status: :not_found unless @video
      end

      def refuse_published
        render json: { error: 'This video is published; change it in Knowledge admin' }, status: :conflict
      end

      def draft_params
        params.require(:video).permit(:title, :description, :module_key, :position, chapters: %i[title start terms],
                                                                                   covers: { routes: [], markers: [] })
      end
    end
  end
end
