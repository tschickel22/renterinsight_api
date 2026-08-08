# frozen_string_literal: true

module Websites
  # The public address of a single home on a dealer site.
  #
  # Until now a home had no URL at all. Listings were addressed as
  # ?vehicle=<id> on the inventory page, and published sites pass
  # enableHistory: false so even that never appeared in the address bar. Nothing
  # could be linked, shared, indexed or given Product markup, because there was
  # no page to hang any of it on.
  #
  # The slug carries the words a buyer would type and ends in the id:
  #
  #   /homes/2026-champion-shoal-creek-1234
  #
  # The trailing id is what makes this safe. Two lots can stock the identical
  # year, make and model, and a home can be renamed after the link is shared, so
  # a purely descriptive slug either collides or rots. Resolution reads the id
  # and the words are decoration for the reader and for search. That is also why
  # a changed slug still resolves rather than 404ing a link someone already has.
  #
  # Compare the category leader, whose equivalent is /homes/007zeb: indexable,
  # but the URL says nothing a search engine can use.
  module HomeUrl
    PREFIX = '/homes'
    # The statuses the public inventory endpoint serves. A URL must not resolve
    # to a home the listing grid would refuse to show.
    SERVABLE_STATUSES = %w[available available_to_order].freeze
    # Long enough for "2026 Champion Homes Shoal Creek Deluxe", short enough that
    # the id stays visible in a browser's address bar.
    MAX_WORDS_LENGTH = 60

    module_function

    def path_for(vehicle)
      return nil if vehicle&.id.blank?

      "#{PREFIX}/#{slug_for(vehicle)}"
    end

    def url_for(vehicle, canonical_host)
      path = path_for(vehicle)
      return nil if path.blank? || canonical_host.blank?

      "https://#{canonical_host}#{path}"
    end

    def slug_for(vehicle)
      words = [vehicle.try(:year), vehicle.try(:make), vehicle.try(:model)]
              .map { |part| part.to_s.strip.presence }.compact.join(' ')
              .parameterize[0, MAX_WORDS_LENGTH].to_s.delete_suffix('-')

      words.presence ? "#{words}-#{vehicle.id}" : vehicle.id.to_s
    end

    # True for any path under the prefix, so the controller can tell a home
    # request apart from a page that simply does not exist.
    def matches?(path)
      path.to_s.start_with?("#{PREFIX}/")
    end

    # The id embedded at the end of the slug, or nil when the path is not one of
    # ours. Deliberately strict: a slug whose tail is not a number is not a home
    # address, and guessing would let /homes/about-us load a random vehicle.
    def vehicle_id_from(path)
      return nil unless matches?(path)

      slug = path.to_s.delete_prefix("#{PREFIX}/").split('/').first.to_s
      id = slug.split('-').last

      id.present? && id.match?(/\A\d+\z/) ? id.to_i : nil
    end
  end
end
