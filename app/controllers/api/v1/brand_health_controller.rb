# frozen_string_literal: true

class Api::V1::BrandHealthController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/brand-health
  def show
    return unless authorize_action!('social_posts', 'read')

    begin
      data = BrandHealthService.fetch_for_company(@company)
    rescue MetaGraphApi::ExpiredTokenError
      return render json: { error: 'Facebook token expired. Please reconnect.' }, status: :unprocessable_entity
    rescue MetaGraphApi::Error => e
      return render json: { error: "Meta API error: #{e.message}" }, status: :bad_gateway
    end

    if data
      render json: data
    else
      render json: { error: 'No Facebook page connected' }, status: :not_found
    end
  end

  # POST   /api/v1/brand-health/posts/:post_id/like
  # DELETE /api/v1/brand-health/posts/:post_id/like
  #
  # The dealership's own Like on its own Page content, via
  # pages_manage_engagement. The Page access token makes the Page the actor, so
  # there is no user identity involved here.
  def like
    toggle_like(:like)
  end

  def unlike
    toggle_like(:unlike)
  end

  private

  def toggle_like(action)
    return unless authorize_action!('social_posts', 'update')

    integration = FacebookIntegration.current_for(@company)
    return render json: { error: 'No Facebook page connected' }, status: :unprocessable_entity unless integration

    object_id = params[:post_id].to_s
    unless own_page_object?(object_id, integration)
      return render json: { error: 'That post does not belong to your Facebook page.' }, status: :forbidden
    end

    begin
      if action == :like
        MetaGraphApi.like_object(object_id, integration.page_access_token)
      else
        MetaGraphApi.unlike_object(object_id, integration.page_access_token)
      end
    rescue MetaGraphApi::ExpiredTokenError
      integration.update(status: 'expired')
      return render json: { error: 'Facebook token expired. Reconnect in Settings.' }, status: :unprocessable_entity
    rescue MetaGraphApi::NotFoundError
      return render json: { error: 'That post no longer exists on Facebook.' }, status: :not_found
    rescue MetaGraphApi::Error => e
      verb = action == :like ? 'like' : 'unlike'
      return render json: { error: "Failed to #{verb} the post: #{e.message}" }, status: :unprocessable_entity
    end

    render json: { post_id: object_id, has_liked: action == :like }
  end

  # A page post id is "{page_id}_{post_id}". Requiring that prefix keeps the
  # page token acting only on its own Page's content: without it, any id the
  # caller invented would be liked as the dealership.
  def own_page_object?(object_id, integration)
    page_id = integration.page_id.to_s
    return false if page_id.blank? || object_id.blank?

    object_id.start_with?("#{page_id}_")
  end
end
