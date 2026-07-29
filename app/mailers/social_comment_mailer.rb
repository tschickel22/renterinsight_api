# frozen_string_literal: true

class SocialCommentMailer < ApplicationMailer
  def new_comment(comment, recipient)
    @comment     = comment
    @recipient   = recipient
    @post        = comment.social_post
    @company     = comment.company
    @location    = @post&.try(:location)
    @sender_user = recipient

    @reply_url    = "#{frontend_base_url}/marketing/social-media?tab=comments&post_id=#{@post&.id}"
    @facebook_url = facebook_permalink_for(@post, @comment)

    subject_text = @post&.headline.presence ||
                   @post&.caption&.truncate(40).presence ||
                   'your post'

    delivery = MailerDeliveryConfigurator.resolve(company: @company, location: @location)

    mail_opts = {
      to:      recipient.email,
      subject: "New comment on \"#{subject_text}\""
    }

    if delivery && (from_email = delivery[:from_address].presence)
      from_name        = delivery[:from_name].presence
      mail_opts[:from] = from_name.present? ? "#{from_name} <#{from_email}>" : from_email
    end

    mail_opts[:from] ||= default_from_address
    message = mail(**mail_opts)

    # Rails 8's wrap_delivery_behavior drops options when delivery_method is a
    # Class, so set the delivery method directly on the Mail::Message afterwards.
    if delivery && message
      message.delivery_method(delivery[:delivery_method], delivery[:delivery_method_options])
    end

    message
  end

  private

  def frontend_base_url
    Brand.app_url
  end

  # Facebook permalinks typically use "{page_id}_{post_id}" or the raw id.
  # We don't always have both pieces; fall back to a search-safe link.
  def facebook_permalink_for(post, _comment)
    return nil unless post&.external_post_id.present?
    return "https://www.facebook.com/#{post.external_post_id}" if post.platform.to_s == 'facebook'
    return "https://www.instagram.com/p/#{post.external_post_id}" if post.platform.to_s == 'instagram'
    nil
  end
end
