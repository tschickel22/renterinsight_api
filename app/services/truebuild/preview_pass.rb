# frozen_string_literal: true

module Truebuild
  # A platform admin looking at a factory as a buyer would, before releasing
  # it (Preview as a buyer on the factory board). The pass stands in for a
  # dealer's inventory token on the public designer endpoints: priced through
  # the dealer chosen, for that one factory's models, whether or not it is
  # released, given to the dealer or on any website. Nothing is saved: a
  # preview makes no design and no lead. Short lived, signed, never stored.
  module PreviewPass
    module_function

    PURPOSE = :truebuild_preview
    TTL = 2.hours

    def issue(company:, factory:, user:)
      verifier.generate({ 'company_id' => company.id, 'factory_id' => factory.id, 'user_id' => user&.id },
                        expires_in: TTL, purpose: PURPOSE)
    end

    # => { 'company_id', 'factory_id', 'user_id' } or nil
    def resolve(pass)
      return nil if pass.blank?

      verifier.verified(pass.to_s, purpose: PURPOSE)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError
      nil
    end

    def verifier = Rails.application.message_verifier(PURPOSE)
  end
end
