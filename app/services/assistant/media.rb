# frozen_string_literal: true

module Assistant
  # Photos and links of a dealer's homes for Quinn AI (E96).
  #
  # Photos go as a picture text (MMS), which carries no link and so works on any
  # number. A home's web address may be texted only on a number whose carrier
  # registration allows links: the shared pool numbers were registered with
  # links, the DealerTide campaigns dealers' provisioned numbers sit on were
  # not, and a dealer's own registration says so on its TwilioAccount
  # (metadata links_allowed). Texting a link on a campaign registered without
  # them risks the carrier filtering the number.
  module Media
    MAX_PHOTOS = 3

    module_function

    def links_allowed?(conversation)
      return true if conversation.pool?

      account = TwilioAccount.active.find_by(phone_number: conversation.sender_number)
      account&.metadata.to_h['links_allowed'] == true
    end

    # The home's page on the dealer's published site, or nil.
    def home_url(company, vehicle)
      path = Websites::HomeUrl.path_for(vehicle)
      return nil unless path

      base = published_site_url(company)
      base && "#{base.chomp('/')}#{path}"
    end

    def published_site_url(company)
      company.websites.where(status: :published).order(published_at: :desc)
             .lazy.map { |site| site.public_url rescue nil }.find(&:present?)
    end

    def photos(vehicle)
      vehicle.public_image_urls.select { |u| u.to_s.start_with?('https://') }.first(MAX_PHOTOS)
    end
  end
end
