# frozen_string_literal: true

# Publishes a single SocialPost via the Meta Graph API. Designed to be enqueued
# from the scheduler, the cron tick job, or (eventually) a manual admin action.
# Isolated so transient failures don't poison the hourly generator run.
class PublishSocialPostJob < ApplicationJob
  queue_as :default

  # Re-enqueue on rate limits with backoff (caller can't control retries so we
  # enforce our own re-enqueue path inside perform).
  RATE_LIMIT_RETRY_DELAY = 15.minutes

  def perform(post_id)
    post = SocialPost.find_by(id: post_id)
    return log("post=#{post_id} missing") unless post
    return log("post=#{post_id} already status=#{post.status}, skipping") unless publishable?(post)

    integration = FacebookIntegration.active.where(company_id: post.company_id).order(:id).first
    unless integration
      mark_failed(post, reason: 'no_integration', error: 'No active Facebook page connected for this company.')
      return
    end

    begin
      result = publish_via_meta(post, integration)
    rescue MetaGraphApi::ExpiredTokenError => e
      integration.update(status: 'expired')
      mark_failed(post, reason: 'expired_token', error: "Facebook token expired: #{e.message}")
      return
    rescue MetaGraphApi::RateLimitError => e
      log("post=#{post.id} rate limited; retrying in #{RATE_LIMIT_RETRY_DELAY.inspect}: #{e.message}")
      self.class.set(wait: RATE_LIMIT_RETRY_DELAY).perform_later(post.id)
      return
    rescue MetaGraphApi::Error => e
      mark_failed(post, reason: 'meta_api_error', error: "Facebook API error: #{e.message}")
      return
    rescue => e
      mark_failed(post, reason: 'unexpected', error: "#{e.class}: #{e.message}")
      return
    end

    external_id = MetaGraphApi.published_post_id(result)

    post.update!(
      status:           'published',
      published_at:     Time.current,
      external_post_id: external_id
    )

    fire_published_webhook(post)

    log("post=#{post.id} published external=#{external_id}")
    post
  end

  private

  # Approved or due-scheduled posts are publishable; everything else is skipped.
  def publishable?(post)
    return true if post.status == 'approved'
    return true if post.status == 'scheduled' && post.scheduled_at.present? && post.scheduled_at <= Time.current
    false
  end

  def publish_via_meta(post, integration)
    if post.platform.to_s == 'instagram'
      # Instagram video is Reels — a different container flow with its own
      # aspect-ratio and duration rules. Fail loudly rather than dropping the
      # video and publishing a bare caption.
      if post.video_url.present?
        raise MetaGraphApi::Error, 'Instagram video posting is not supported yet. Publish this to Facebook instead.'
      end

      image_url = Array(post.image_urls).first
      raise MetaGraphApi::Error, 'Instagram posts require at least one image.' if image_url.blank?

      ig_account_id = integration.metadata.to_h.deep_stringify_keys['instagram_business_account_id']
      raise MetaGraphApi::Error, 'No Instagram Business Account linked.' if ig_account_id.blank?

      MetaGraphApi.publish_instagram_post(
        ig_account_id,
        integration.page_access_token,
        caption:   build_caption(post),
        image_url: image_url
      )
    elsif post.video_url.present?
      # Facebook can't mix a video with photos in one post, so video wins and
      # any attached images are ignored rather than silently half-published.
      MetaGraphApi.publish_page_video(
        integration.page_id,
        integration.page_access_token,
        message:   build_caption(post),
        video_url: post.video_url
      )
    else
      # Multiple images become a carousel; one or none takes the original path.
      # Same pages_manage_posts permission either way.
      images = Array(post.image_urls).map { |u| u.to_s.strip }.reject(&:blank?)

      if images.length > 1
        MetaGraphApi.publish_page_carousel(
          integration.page_id,
          integration.page_access_token,
          message:    build_caption(post),
          image_urls: images,
          link:       post.tagged_url
        )
      else
        MetaGraphApi.publish_page_post(
          integration.page_id,
          integration.page_access_token,
          message:   build_caption(post),
          link:      post.tagged_url,
          photo_url: images.first
        )
      end
    end
  end

  # Appends hashtags from generation_context since SocialPost has no dedicated
  # hashtags column.
  def build_caption(post)
    parts = []
    parts << post.caption if post.caption.present?

    tags = extract_hashtags(post)
    parts << tags.map { |h| "##{h.to_s.delete('#').strip}" }.reject(&:empty?).join(' ') if tags.any?
    parts.join("\n\n")
  end

  def extract_hashtags(post)
    raw = post.generation_context.is_a?(Hash) ? post.generation_context.deep_stringify_keys['hashtags'] : nil
    return Array(raw) if raw.is_a?(Array)
    return JSON.parse(raw) if raw.is_a?(String) && raw.strip.start_with?('[')
    []
  rescue JSON::ParserError
    []
  end

  def mark_failed(post, reason:, error:)
    ctx = post.generation_context.is_a?(Hash) ? post.generation_context.deep_stringify_keys : {}
    post.update!(
      status: 'failed',
      generation_context: ctx.merge(
        'publish_failure' => {
          'reason'  => reason,
          'error'   => error,
          'failed_at' => Time.current.iso8601
        }
      )
    )
    log("post=#{post.id} failed reason=#{reason}: #{error}")
  end

  def fire_published_webhook(post)
    return unless defined?(WebhookService)

    WebhookService.fire(
      company_id: post.company_id,
      event:      'social_post.published',
      payload: {
        id:              post.id,
        platform:        post.platform,
        intent_category: post.intent_category,
        post_type:       post.post_type,
        headline:        post.headline,
        caption:         post.caption,
        published_at:    post.published_at,
        external_post_id: post.external_post_id
      }
    )
  rescue => e
    Rails.logger.error "[PublishSocialPostJob] webhook fire failed: #{e.message}"
  end

  def log(msg)
    Rails.logger.info "[PublishSocialPostJob] #{msg}"
  end
end
