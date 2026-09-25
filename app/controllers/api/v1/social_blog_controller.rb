# frozen_string_literal: true

# The blog version of a social post: the company's blog settings, writing a
# version with AI, and reading or saving the one attached to a post.
#
# Generating does not save anything, the same as POST /social-posts/generate.
# The compose screen saves the social post first, then PUTs the blog version.
class Api::V1::SocialBlogController < ApplicationController
  before_action :set_company_scope
  include ModuleAccessRequired
  require_any_module! 'marketing.social_media', 'marketing.automation', log_only: true
  before_action :set_post, only: %i[show upsert]

  # GET /api/v1/social-blog/settings
  def settings
    return unless authorize_action!('social_posts', 'read')

    render json: settings_payload
  end

  # PUT /api/v1/social-blog/settings
  def update_settings
    return unless authorize_action!('social_posts', 'update')

    # Our marketing sites are for our own companies. A client pointed at one
    # would publish onto our website.
    if params[:destination].to_s == 'marketing_site' && !current_user&.platform_admin?
      return render json: { error: 'Only a platform admin can publish to a marketing site' }, status: :forbidden
    end

    blog_settings.update(
      website_id:         params[:website_id],
      default_on:         params[:default_on],
      destination:        params[:destination],
      marketing_site_key: params[:marketing_site_key]
    )
    render json: settings_payload
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/social-blog/generate
  def generate
    return unless authorize_action!('social_posts', 'create')

    vehicle = params[:vehicle_id].present? ? @company.vehicles.find_by(id: params[:vehicle_id]) : nil
    result = SocialBlog::Generator.generate(
      company:         @company,
      caption:         params[:caption],
      headline:        params[:headline],
      description:     params[:description],
      hashtags:        Array(params[:hashtags]),
      intent_category: params[:intent_category],
      vehicle:         vehicle
    )
    render json: result
  rescue SocialBlog::Generator::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /api/v1/social-posts/:social_post_id/blog
  def show
    return unless authorize_action!('social_posts', 'read')

    render json: { blog: serialize(@post.blog_cross_post) }
  end

  # PUT /api/v1/social-posts/:social_post_id/blog
  #
  # Once published the blog post lives on the site, and is edited there.
  def upsert
    return unless authorize_action!('social_posts', 'update')

    cross_post = @post.blog_cross_post || @post.build_blog_cross_post(company: @company)
    if cross_post.published?
      return render json: { error: 'The blog post is already published. Edit it in the website builder.' },
                    status: :unprocessable_entity
    end

    attrs = blog_params.to_h
    attrs['content'] = SocialBlog::Generator.sanitize_html(attrs['content']) if attrs.key?('content')
    if attrs.key?('website_id') && attrs['website_id'].present? &&
       !blog_settings.candidate_sites.exists?(id: attrs['website_id'])
      return render json: { error: 'That website does not belong to this company' }, status: :unprocessable_entity
    end

    cross_post.assign_attributes(attrs)
    cross_post.company_id = @company.id
    aim(cross_post) unless cross_post.status == 'skipped'
    # A failed attempt goes back in line when the author saves it again.
    cross_post.status = 'pending' if cross_post.status == 'failed' && !attrs.key?('status')
    cross_post.error  = nil if cross_post.status == 'pending'

    if cross_post.save
      render json: { blog: serialize(cross_post) }
    else
      render json: { errors: cross_post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def set_post
    @post = @company.social_posts.active.find_by(id: params[:social_post_id])
    render json: { error: 'Not found' }, status: :not_found unless @post
  end

  # Where a pending version goes follows the company setting at save time, so
  # changing the setting moves drafts that have not gone out yet.
  def aim(cross_post)
    target = blog_settings.resolve_target(location_id: @post.location_id || current_location_id)
    if target&.destination == 'marketing_site'
      cross_post.destination        = 'marketing_site'
      cross_post.marketing_site_key = target.marketing_site_key
      cross_post.website_id         = nil
    else
      cross_post.destination        = 'website_builder'
      cross_post.marketing_site_key = nil
      cross_post.website_id       ||= target&.website_id
    end
  end

  def blog_settings
    @blog_settings ||= SocialBlog::Settings.new(@company)
  end

  def blog_params
    params.require(:blog).permit(
      :status, :title, :slug, :excerpt, :content, :seo_title, :seo_description,
      :featured_image_url, :website_id, :generated_at, :ai_generation_version, tags: []
    ).tap do |p|
      p.delete(:status) unless %w[pending skipped].include?(p[:status])
    end
  end

  def settings_payload
    sites  = blog_settings.candidate_sites.order(:name).to_a
    target = blog_settings.resolve_target(location_id: current_location_id)
    {
      settings: blog_settings.to_h,
      resolved_website_id: target&.website_id,
      resolved_target: target && {
        destination:        target.destination,
        website_id:         target.website_id,
        marketing_site_key: target.marketing_site_key,
        name:               target.name
      },
      # Only listed for platform admins, who alone can choose one. No secrets.
      marketing_sites: current_user&.platform_admin? ? SocialBlog::MarketingSites.all.map { |m| { key: m.key, name: m.name, site_url: m.site_url } } : [],
      websites: sites.map do |w|
        {
          id:            w.id,
          name:          w.name,
          status:        w.status,
          location_id:   w.location_id,
          public_url:    w.public_url,
          has_blog_page: SocialBlog::Settings.blog_page_path(w).present?
        }
      end
    }
  end

  def serialize(cross_post)
    return nil unless cross_post

    cross_post.as_json(only: %i[
      id status destination website_id marketing_site_key title slug excerpt content seo_title
      seo_description tags featured_image_url generated_at external_id public_url published_at error
    ])
  end
end
