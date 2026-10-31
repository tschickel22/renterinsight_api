# frozen_string_literal: true

module Api
  module Admin
    # Platform admin: help article screenshots (backlog E89). Recipes are
    # edited here or kept in db/guide/screenshots.yml; the pictures come only
    # from the nightly run on staging.
    class KnowledgeScreenshotsController < ApplicationController
      before_action :authenticate_user!
      before_action :require_platform_admin!
      before_action :set_shot, only: %i[update destroy text_checked]

      RECIPE_PARAMS = [:key, :module_key, :title, :alt_text, :route, :crop_marker, :padding, :mobile_crop_marker,
                       { steps: %i[click fill value wait highlight], mobile_steps: %i[click fill value wait highlight], mask_selectors: [] }].freeze

      def index
        shots = Knowledge::Screenshot.ordered.to_a
        # Which articles show each shot, from one pass over the articles.
        used = Hash.new { |h, k| h[k] = [] }
        Knowledge::Article.where('content LIKE ?', '%shot:%').find_each do |a|
          Knowledge::Screenshot.keys_in(a.content).each { |k| used[k] << { slug: a.slug, title: a.title, is_published: a.is_published } }
        end
        render json: {
          screenshots: shots.map { |s| s.as_api_json.merge(articles: used[s.key]) },
          capture_here: !Guide::ApprovedHelpSync.configured?
        }
      end

      def create
        shot = Knowledge::Screenshot.new(recipe_params.merge(source: 'admin'))
        return render(json: { screenshot: shot.as_api_json }, status: :created) if shot.save

        render json: { error: shot.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      def update
        return render(json: { screenshot: @shot.as_api_json }) if @shot.update(recipe_params.except(:key))

        render json: { error: @shot.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      # The screen changed and someone checked the articles' text still fits.
      def text_checked
        @shot.update!(needs_review: false)
        render json: { screenshot: @shot.as_api_json }
      end

      def destroy
        @shot.destroy!
        head :no_content
      end

      private

      def set_shot
        @shot = Knowledge::Screenshot.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      def recipe_params
        params.require(:screenshot).permit(*RECIPE_PARAMS)
      end
    end
  end
end
