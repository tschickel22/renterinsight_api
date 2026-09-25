# frozen_string_literal: true

module SocialBlog
  # Puts a link to the blog version in the Facebook post.
  #
  # Facebook will not let us edit the text of a published post that has a
  # photo or video, which is most of them, so the link cannot be added
  # afterwards. Instead the blog version is published just before the social
  # post, and its address goes into the text that is sent.
  #
  # A website-builder post is live the moment it is saved. A marketing-site
  # post needs its rebuild, so its link can 404 for the minute or two that takes.
  module SocialLink
    module_function

    # Publishes the blog version now and returns its tracked link, or nil when
    # there is nothing to link to. Never raises: if the blog cannot go out, the
    # social post still does, and PublishSocialBlogJob records why the blog did not.
    #
    # allow_write: false skips a version nobody wrote yet, since writing one
    # takes about 20 seconds and the Publish button is waiting.
    def prepare(post, allow_write:)
      return nil unless post.platform.to_s == 'facebook'

      existing = link_for(post)
      return existing if existing

      cross_post = post.blog_cross_post
      return nil unless cross_post&.pending?
      return nil unless Settings.new(post.company).to_h['link_from_social']

      unless cross_post.written?
        return nil unless allow_write

        AutoAttach.write!(cross_post, post)
      end

      publisher = cross_post.destination == 'marketing_site' ? MarketingSitePublisher : WebsiteBuilderPublisher
      publisher.call(cross_post)
      return nil unless cross_post.published? && cross_post.public_url.present? && cross_post.error.blank?

      link = tracked(cross_post.public_url, post)
      ctx  = (post.generation_context || {}).deep_stringify_keys.merge('blog_link' => link)
      post.update_columns(generation_context: ctx, updated_at: Time.current)
      link
    rescue Generator::Error, WebsiteBuilderPublisher::Error, MarketingSitePublisher::Error,
           ActiveRecord::RecordInvalid => e
      Rails.logger.warn "[SocialBlog::SocialLink] post=#{post.id} no link: #{e.message}"
      nil
    end

    def link_for(post)
      ctx = post.generation_context
      ctx.is_a?(Hash) ? ctx.deep_stringify_keys['blog_link'].presence : nil
    end

    # The line that goes in the post text, between the caption and hashtags.
    def line_for(post)
      link = link_for(post)
      link && "Read the full post: #{link}"
    end

    # Tagged so a visit from the post is attributed to it, the same way the
    # post's own link is.
    def tracked(url, post)
      uri = URI.parse(url)
      query = URI.decode_www_form(uri.query.to_s).to_h.merge(
        'utm_source' => 'facebook', 'utm_medium' => 'social',
        'utm_campaign' => 'blog', 'utm_content' => post.id.to_s
      )
      uri.query = URI.encode_www_form(query)
      uri.to_s
    rescue URI::InvalidURIError
      url
    end
  end
end
