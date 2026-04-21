# frozen_string_literal: true

class SocialPostMailer < ApplicationMailer
  # Notifies an approver that a scheduled social post needs review.
  def approval_needed(post, recipient)
    @post        = post
    @recipient   = recipient
    @company     = post.company
    @location    = post.try(:location)
    @sender_user = recipient
    @vehicle     = post.vehicle

    @approve_url = "#{api_base_url}/api/v1/social-posts/#{post.id}/email_approve?token=#{SocialPostMailer.signed_action_token(post_id: post.id, action: 'approve')}"
    @edit_url    = "#{frontend_base_url}/marketing/social-media/compose/#{post.id}"
    @decline_url = "#{api_base_url}/api/v1/social-posts/#{post.id}/email_decline?token=#{SocialPostMailer.signed_action_token(post_id: post.id, action: 'decline')}"
    @skip_url    = skip_url_for(post)

    delivery = MailerDeliveryConfigurator.resolve(company: @company, location: @location)

    mail_opts = {
      to:      recipient.email,
      subject: "Social Post Ready for Review: #{post.headline.presence || post.intent_category.to_s.titleize}"
    }

    if delivery && (from_email = delivery[:from_address].presence)
      from_name        = delivery[:from_name].presence
      mail_opts[:from] = from_name.present? ? "#{from_name} <#{from_email}>" : from_email
    end

    mail_opts[:from] ||= default_from_address
    message = mail(**mail_opts)

    # Rails 8's wrap_delivery_behavior drops the options hash when delivery_method
    # is a Class, so we bypass it and set the delivery method directly on the
    # Mail::Message. This is the only path that actually forwards our settings.
    if delivery && message
      message.delivery_method(delivery[:delivery_method], delivery[:delivery_method_options])
    end

    message
  end

  private

  def api_base_url
    ENV['RAILS_API_URL'].presence ||
      ENV['API_BASE_URL'].presence ||
      (Rails.env.production? ? 'https://api.renterinsight.com' : default_dev_api_url)
  end

  # Mirror the URL config ActionMailer is already using for this env so the
  # email links target the same server that's actually serving the app.
  def default_dev_api_url
    opts = Rails.application.config.action_mailer.default_url_options || {}
    host     = opts[:host].presence || 'localhost'
    port     = opts[:port] || ENV['PORT'] || 3001
    protocol = opts[:protocol].presence || 'https'
    "#{protocol}://#{host}:#{port}"
  end

  def frontend_base_url
    ENV['FRONTEND_URL'].presence ||
      (Rails.env.production? ? 'https://app.renterinsight.com' : 'https://localhost:5173')
  end

  def skip_url_for(post)
    token = SocialPostMailer.signed_action_token(post_id: post.id, action: 'skip')
    "#{api_base_url}/api/v1/social-posts/#{post.id}/skip?token=#{token}"
  end

  # Signed, single-scope action token so the "Skip" link in email doesn't need
  # to authenticate. Verifiable without session state.
  def self.signed_action_token(post_id:, action:)
    verifier.generate({ post_id: post_id, action: action, nonce: SecureRandom.hex(8) }, expires_in: 7.days)
  end

  def self.decode_action_token(token)
    verifier.verify(token)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def self.verifier
    ActiveSupport::MessageVerifier.new(
      Rails.application.secret_key_base,
      digest: 'SHA256',
      serializer: JSON
    )
  end
end
