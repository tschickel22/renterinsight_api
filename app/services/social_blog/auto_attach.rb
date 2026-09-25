# frozen_string_literal: true

module SocialBlog
  # Gives a post written by the scheduler or a workflow its blog version, so it
  # goes out with the post like one written by hand.
  #
  # Written now, not at publish, so the approval email can show it. If writing
  # fails the version is still attached, and PublishSocialBlogJob writes it
  # when the post publishes.
  class AutoAttach
    # wanted: the schedule's own choice; nil follows the company default.
    def self.call(post, wanted: nil)
      return nil if post.post_type.to_s == 'rep_personal'

      settings = Settings.new(post.company)
      wanted   = settings.to_h['default_on'] if wanted.nil?
      return nil unless wanted

      target = settings.resolve_target(location_id: post.location_id)
      return nil unless target

      cross_post = post.create_blog_cross_post!(
        company:            post.company,
        status:             'pending',
        destination:        target.destination,
        website_id:         target.website_id,
        marketing_site_key: target.marketing_site_key,
        author_name:        settings.to_h['default_author_name']
      )
      write(cross_post, post)
      cross_post
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.error "[SocialBlog::AutoAttach] post=#{post.id} #{e.message}"
      nil
    end

    def self.write(cross_post, post)
      write!(cross_post, post)
    rescue Generator::Error => e
      Rails.logger.warn "[SocialBlog::AutoAttach] post=#{post.id} not written yet: #{e.message}"
    end

    # Raises Generator::Error, for callers that record the failure.
    def self.write!(cross_post, post)
      hashtags = post.generation_context.is_a?(Hash) ? Array(post.generation_context['hashtags']) : []
      result = Generator.generate(
        company: post.company, caption: post.caption, headline: post.headline,
        description: post.description, hashtags: hashtags,
        intent_category: post.intent_category, vehicle: post.vehicle
      )
      cross_post.update!(result.merge(generated_at: Time.current))
    end
  end
end
