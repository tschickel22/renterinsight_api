# frozen_string_literal: true

# Publishes the blog version of a social post once the social post itself is
# live. Enqueued by SocialPost when its status becomes published.
#
# If the blog version was never written (the box was ticked but the author did
# not open the panel), it is written here from the published post.
class PublishSocialBlogJob < ApplicationJob
  queue_as :default

  def perform(social_post_id)
    post       = SocialPost.find_by(id: social_post_id)
    cross_post = post&.blog_cross_post
    return unless cross_post&.pending?
    return unless post.status == 'published'

    SocialBlog::AutoAttach.write!(cross_post, post) unless cross_post.written?
    publisher_for(cross_post).call(cross_post)
    Rails.logger.info "[PublishSocialBlogJob] post=#{post.id} blog=#{cross_post.external_id} published"
  rescue StandardError => e
    cross_post&.update_columns(status: 'failed', error: e.message, updated_at: Time.current)
    Rails.logger.error "[PublishSocialBlogJob] post=#{social_post_id} failed: #{e.message}"
  end

  private

  def publisher_for(cross_post)
    cross_post.destination == 'marketing_site' ? SocialBlog::MarketingSitePublisher : SocialBlog::WebsiteBuilderPublisher
  end
end
