# frozen_string_literal: true

module Api
  module V1
    # The nightly screenshot run (backlog E89, scripts/screenshot-capture.cjs
    # in the frontend repo) signs in as the tour-check account, asks for the
    # recipes and sends back each picture it took.
    #
    # Pictures are only ever taken in a demo company, and never on a server
    # that copies its help from another (production): a real dealer's
    # screen must not end up in a help article.
    class HelpScreenshotsController < ApplicationController
      before_action :authenticate_user!
      before_action :require_capture_account!

      UPLOAD_TYPES = %w[image/png].freeze

      # GET /api/v1/help_screenshots/recipes
      def recipes
        Guide::ScreenshotLoader.load_if_changed!
        render json: { screenshots: Knowledge::Screenshot.ordered.map(&:as_recipe_json) }
      end

      # POST /api/v1/help_screenshots/:key/capture
      #   size=desktop|mobile, status=ok|broken, error, file (PNG, only when the
      #   picture changed), width, height, change_score, commit_sha, commit_at
      def capture
        shot = Knowledge::Screenshot.find_by(key: params[:key])
        return render(json: { error: 'Not found' }, status: :not_found) unless shot

        size = params[:size].to_s
        status = params[:status].to_s
        unless Knowledge::Screenshot::SIZES.include?(size) && %w[ok broken].include?(status)
          return render(json: { error: 'size must be desktop or mobile, status ok or broken' }, status: :unprocessable_entity)
        end

        url = nil
        file = params[:file]
        if status == 'ok' && file.respond_to?(:original_filename)
          return render(json: { error: 'A screenshot must be a PNG' }, status: :unprocessable_entity) unless png?(file)

          url = S3UploadService.new.upload(file, key: "help-screenshots/#{shot.key}-#{size}-#{Time.current.to_i}.png")[:url]
        end
        shot.record_capture!(size: size, status: status, url: url, error: params[:error],
                             width: params[:width].presence&.to_i, height: params[:height].presence&.to_i,
                             change_score: params[:change_score].presence&.to_f, commit_sha: params[:commit_sha].presence,
                             commit_at: (Time.zone.parse(params[:commit_at].to_s) rescue nil))
        render json: { screenshot: shot.as_api_json }
      rescue RuntimeError => e
        render json: { error: e.message }, status: :bad_gateway
      end

      private

      def require_capture_account!
        allowed = Guide::Checker.user?(current_user) && current_user.company&.is_demo? && !Guide::ApprovedHelpSync.configured?
        return true if allowed

        render json: { error: 'Screenshots are only taken by the tour-check account, in a demo company, on staging' }, status: :forbidden
        false
      end

      # The type the browser sent, and the file's own first bytes.
      def png?(file)
        return false unless UPLOAD_TYPES.include?(file.content_type.to_s)

        path = file.respond_to?(:tempfile) ? file.tempfile.path : file.path
        File.binread(path, 8) == "\x89PNG\r\n\x1A\n".b
      end
    end
  end
end
