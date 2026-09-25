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
      return nil unless cross_post
      return nil unless Settings.new(post.company).to_h['link_from_social']
      # Published on its own earlier ("Publish Blog Post Only"): link to it as it is.
      return remember(post, cross_post) if cross_post.linkable?
      return nil unless cross_post.pending?

      unless cross_post.written?
        return nil unless allow_write

        AutoAttach.write!(cross_post, post)
      end

      cross_post.publisher.call(cross_post)
      cross_post.linkable? ? remember(post, cross_post) : nil
    # Anything at all: this runs in the middle of publishing to Facebook, and a
    # parse error here once turned a Publish click into a 500 with nothing posted.
    rescue StandardError => e
      Rails.logger.warn "[SocialBlog::SocialLink] post=#{post.id} no link: #{e.class}: #{e.message}"
      nil
    end

    def remember(post, cross_post)
      link = tracked(cross_post.public_url, post)
      ctx  = (post.generation_context || {}).deep_stringify_keys.merge('blog_link' => link)
      post.update_columns(generation_context: ctx, updated_at: Time.current)
      link
    end

    def link_for(post)
      ctx = post.generation_context
      ctx.is_a?(Hash) ? ctx.deep_stringify_keys['blog_link'].presence : nil
    end

    # The line that goes in the post text, between the caption and hashtags.
    # Nothing when the author already put the address in the post, from the
    # compose screen's Copy link, so the link does not appear twice.
    def line_for(post)
      link = link_for(post)
      return nil if link.nil?
      return nil if post.caption.to_s.include?(bare(link))

      "Read the full post: #{link}"
    end

    # The address without tracking or a trailing slash, for spotting it in text.
    def bare(url)
      url.to_s.sub(/\?.*\z/, '').chomp('/')
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
