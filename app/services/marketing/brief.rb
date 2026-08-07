# frozen_string_literal: true

module Marketing
  # One brief, many generators.
  #
  # Campaign Desk's whole premise is that a single prompt produces the email,
  # the SMS, the social post and the landing page as one coherent campaign. That
  # only works if every generator is given the SAME brief — otherwise the
  # landing page argues with the email that drove traffic to it, and the dealer
  # gets four assets that read as though four people wrote them.
  #
  # So this is the contract, and generators accept it rather than owning a
  # prompt of their own. It is also what lets the landing page builder be used
  # standalone: the same object built from one form field instead of an
  # orchestrator.
  Brief = Struct.new(
    :company,
    :user,
    :location,
    # What the marketer actually asked for, in their words.
    :prompt,
    # Optional grounding. A scanned site or an uploaded product sheet, already
    # normalised — so the generator writes from the client's real content
    # rather than inventing plausible-sounding filler.
    :site_content_profile,
    # Free-text offer framing: "$0 down through March", "model year run-out".
    :offer,
    :audience,
    :tone,
    :call_to_action,
    # Inventory scope, when the asset should show real stock.
    :inventory_config,
    keyword_init: true
  ) do
    def profile
      site_content_profile&.profile || {}
    end

    def brand_name
      profile.dig('brand', 'name').presence || company&.name
    end

    # The generator prompt reads this. Only the parts a writer would actually
    # use — a full profile is mostly link inventory and vendor detections that
    # would crowd out the copy.
    def grounding
      return {} if profile.blank?

      {
        'brand' => profile['brand'],
        'contact' => profile['contact'],
        'copy' => profile['copy'],
        'seo' => profile['seo']
      }.compact
    end

    def to_h_for_prompt
      {
        prompt: prompt,
        offer: offer,
        audience: audience,
        tone: tone,
        call_to_action: call_to_action,
        brand_name: brand_name,
        location: location&.name
      }.compact
    end
  end
end
