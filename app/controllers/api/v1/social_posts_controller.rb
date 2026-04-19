# frozen_string_literal: true

class Api::V1::SocialPostsController < ApplicationController
  before_action :set_company_scope
  before_action :set_post, only: %i[show update destroy approve publish]

  def index
    return unless authorize_action!('social_posts', 'read')
    posts = @company.social_posts.active.order(created_at: :desc).limit(100)
    render json: posts.map { |p| serialize(p) }
  end

  def show
    return unless authorize_action!('social_posts', 'read')
    render json: serialize(@post, detailed: true)
  end

  def create
    return unless authorize_action!('social_posts', 'update')

    post = @company.social_posts.new(permitted_params)
    post.created_by_user_id = current_user&.id
    if post.save
      render json: serialize(post), status: :created
    else
      render json: { errors: post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('social_posts', 'update')

    if @post.update(permitted_params)
      render json: serialize(@post, detailed: true)
    else
      render json: { errors: @post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('social_posts', 'delete')

    @post.update!(is_deleted: true)
    head :no_content
  end

  def approve
    return unless authorize_action!('social_posts', 'update')

    @post.update!(status: 'approved', nurture_approved: true)
    render json: serialize(@post)
  end

  def publish
    return unless authorize_action!('social_posts', 'update')

    @post.update!(status: 'published', published_at: Time.current)
    render json: serialize(@post)
  end

  def generate
    return unless authorize_action!('social_posts', 'update')

    # Placeholder for AI generation endpoint — full implementation ships separately.
    render json: { status: 'not_implemented', message: 'AI generation endpoint is a stub' }, status: :accepted
  end

  def stats
    return unless authorize_action!('social_posts', 'read')

    posts = @company.social_posts.active
    render json: {
      total:       posts.count,
      by_status:   posts.group(:status).count,
      by_intent:   posts.group(:intent_category).count,
      total_leads: posts.sum(:lead_count),
      total_deals: posts.sum(:deal_count),
      attributed_revenue: posts.sum(:attributed_revenue)
    }
  end

  private

  def set_post
    @post = @company.social_posts.active.find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @post
  end

  def permitted_params
    params.require(:social_post).permit(
      :location_id, :social_account_id, :vehicle_id,
      :post_type, :intent_category, :platform, :status,
      :caption, :headline, :description, :cta_type,
      :tagged_url, :utm_campaign, :utm_content,
      :scheduled_at, :nurture_approved, :nurture_sequence_id,
      :ai_generation_version,
      image_urls: [],
      generation_context: {}
    )
  end

  def serialize(p, detailed: false)
    base = {
      id:                p.id,
      post_type:         p.post_type,
      intent_category:   p.intent_category,
      platform:          p.platform,
      status:            p.status,
      caption:           p.caption,
      headline:          p.headline,
      image_urls:        p.image_urls,
      cta_type:          p.cta_type,
      scheduled_at:      p.scheduled_at,
      published_at:      p.published_at,
      lead_count:        p.lead_count,
      deal_count:        p.deal_count,
      attributed_revenue: p.attributed_revenue,
      vehicle_id:        p.vehicle_id,
      created_at:        p.created_at,
      updated_at:        p.updated_at
    }
    if detailed
      base.merge!(
        description:        p.description,
        tagged_url:         p.tagged_url,
        utm_campaign:       p.utm_campaign,
        utm_content:        p.utm_content,
        reach:              p.reach,
        impressions:        p.impressions,
        engagement_count:   p.engagement_count,
        link_clicks:        p.link_clicks,
        metrics_synced_at:  p.metrics_synced_at,
        nurture_approved:   p.nurture_approved,
        nurture_sequence_id: p.nurture_sequence_id,
        generation_context: p.generation_context
      )
    end
    base
  end
end
