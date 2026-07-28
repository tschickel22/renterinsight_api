# frozen_string_literal: true

# Syncs Facebook/Instagram comments into our local social_comments table every
# 15 minutes. For brand-new audience comments (not from our own page), builds
# a Notification row per recipient, pushes to ActionCable, and (optionally)
# fires an email via SocialCommentMailer based on company-scoped settings.
class SyncSocialCommentsJob < ApplicationJob
  queue_as :default

  LOOKBACK_DAYS = 30
  MAX_COMMENTS_PER_POST = 100

  def perform
    company_ids = FacebookIntegration.active.distinct.pluck(:company_id)

    total_synced = 0
    total_new    = 0
    failed       = 0

    Company.where(id: company_ids).find_each do |company|
      settings = SocialMediaSettingsService.for_company(company)
      next unless settings['comment_sync_enabled']

      integration = FacebookIntegration.current_for(company)
      next unless integration

      synced_count, new_count = sync_company(company, integration, settings)
      total_synced += synced_count
      total_new    += new_count
    rescue => e
      failed += 1
      Rails.logger.error "[SyncSocialCommentsJob] company=#{company.id} failed: #{e.class}: #{e.message}"
    end

    Rails.logger.info "[SyncSocialCommentsJob] synced=#{total_synced} new=#{total_new} failed=#{failed}"
  end

  private

  def sync_company(company, integration, settings)
    synced = 0
    new_count = 0

    posts_scope = company.social_posts.where(status: 'published')
                         .where.not(external_post_id: nil)
                         .where('published_at >= ?', LOOKBACK_DAYS.days.ago)

    posts_scope.find_each do |post|
      begin
        response = MetaGraphApi.get_post_comments(post.external_post_id, integration.page_access_token, limit: MAX_COMMENTS_PER_POST)
      rescue MetaGraphApi::ExpiredTokenError => e
        integration.update(status: 'expired')
        Rails.logger.warn "[SyncSocialCommentsJob] company=#{company.id} token expired: #{e.message}"
        return [synced, new_count]
      rescue MetaGraphApi::RateLimitError => e
        Rails.logger.warn "[SyncSocialCommentsJob] company=#{company.id} rate limited: #{e.message}"
        return [synced, new_count]
      rescue MetaGraphApi::NotFoundError
        next
      rescue MetaGraphApi::Error => e
        Rails.logger.error "[SyncSocialCommentsJob] post=#{post.id} error: #{e.message}"
        next
      end

      comments = Array(response['data'])
      comments.each do |raw|
        created, record = upsert_comment(company, post, raw)
        synced += 1
        next unless created

        new_count += 1
        next if record.is_from_page?
        notify_recipients(company, post, record, settings)
      end
    end

    [synced, new_count]
  end

  # Upsert by external_comment_id. Returns [was_newly_created?, record].
  def upsert_comment(company, post, raw)
    external_id = raw['id']
    return [false, nil] if external_id.blank?

    existing = SocialComment.find_by(external_comment_id: external_id)
    from_meta    = raw['from'].is_a?(Hash) ? raw['from'] : {}
    author_id    = from_meta['id'].to_s
    is_from_page = author_id.present? && author_id == post.try(:social_account)&.external_id.to_s ||
                   author_id == page_id_for(company).to_s

    attrs = {
      company_id:         company.id,
      social_post_id:     post.id,
      external_comment_id: external_id,
      external_post_id:   post.external_post_id,
      platform:           post.platform,
      author_name:        from_meta['name'],
      author_id:          from_meta['id'],
      author_profile_pic: from_meta.dig('picture', 'data', 'url'),
      message:            raw['message'],
      parent_comment_id:  raw.dig('parent', 'id'),
      is_reply:           raw.dig('parent', 'id').present?,
      is_from_page:       is_from_page,
      commented_at:       parse_time(raw['created_time']),
      status:             'active'
    }

    if existing
      existing.update!(attrs.slice(:message, :author_name, :author_profile_pic))
      [false, existing]
    else
      record = SocialComment.create!(attrs)
      [true, record]
    end
  end

  def page_id_for(company)
    FacebookIntegration.current_for(company)&.page_id
  end

  def parse_time(value)
    return nil if value.blank?
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # ------------------------------------------------------------------
  # Notifications
  # ------------------------------------------------------------------
  def notify_recipients(company, post, comment, settings)
    recipient_ids = resolve_recipient_ids(company, post, settings)
    return if recipient_ids.empty?

    User.where(id: recipient_ids, company_id: company.id).find_each do |user|
      notification = create_notification!(company, user, post, comment)
      broadcast(user, post, comment, notification) if settings['push_on_comments']
      send_email(user, comment) if settings['email_on_comments'] && user.email.present?
    rescue => e
      Rails.logger.error "[SyncSocialCommentsJob] notify user=#{user.id}: #{e.class}: #{e.message}"
    end
  end

  def resolve_recipient_ids(_company, post, settings)
    ids = Array(settings['comment_notification_users']).map(&:to_i).reject(&:zero?)
    ids << post.created_by_user_id if settings['notify_post_creator'] && post.created_by_user_id.present?
    ids.uniq
  end

  def create_notification!(company, user, post, comment)
    title = "New comment on #{post.headline.presence || post.platform.to_s.titleize} post"
    message = "#{comment.author_name.to_s.presence || 'Someone'}: #{comment.message.to_s.truncate(160)}"

    Notification.create!(
      recipient_type:    'User',
      recipient_id:      user.id,
      company_id:        company.id,
      location_id:       post.location_id,
      notification_type: 'social_comment',
      category:          'communications',
      priority:          'normal',
      title:             title,
      message:           message,
      notifiable_type:   'SocialPost',
      notifiable_id:     post.id,
      actor_type:        'SocialComment',
      actor_id:          comment.id,
      action_url:        "/marketing/social-media?tab=comments&post_id=#{post.id}",
      action_text:       'View & Reply',
      action_data:       { social_comment_id: comment.id, social_post_id: post.id }.deep_stringify_keys,
      metadata:          { platform: comment.platform }.deep_stringify_keys
    )
  end

  def broadcast(user, post, comment, notification)
    ActionCable.server.broadcast(
      "user_notifications_#{user.id}",
      {
        type:        'social_comment',
        title:       notification.title,
        description: notification.message,
        entityType:  'social_post',
        entityId:    post.id,
        entityName:  post.headline.presence || post.caption.to_s.truncate(50).presence || "Post ##{post.id}",
        priority:    'medium',
        notification: {
          id:              notification.id,
          social_comment_id: comment.id,
          external_comment_id: comment.external_comment_id,
          author_name:     comment.author_name,
          platform:        comment.platform,
          action_url:      notification.action_url
        }
      }
    )
  rescue => e
    Rails.logger.error "[SyncSocialCommentsJob] ActionCable broadcast failed: #{e.message}"
  end

  def send_email(user, comment)
    SocialCommentMailer.new_comment(comment, user).deliver_later
  rescue => e
    Rails.logger.error "[SyncSocialCommentsJob] email send failed for user=#{user.id}: #{e.message}"
  end
end
