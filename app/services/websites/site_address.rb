# frozen_string_literal: true

module Websites
  # The hostname a tenant site is served on, and the only place that knows how
  # one is spelled.
  #
  # Staging and production share the mydealertide.com zone, so without a
  # distinguishing mark a staging site and a real dealer site want the identical
  # hostname. Subdomain uniqueness is enforced per database and cannot see
  # across environments, so nothing catches the collision: the second
  # environment to save simply rebinds the Worker route, and whichever site loses
  # goes dark. Measured before this existed — a staging publish created
  # mhmasters.mydealertide.com pointing at production, which had no such site.
  #
  # The mark is a suffix on the LABEL (mhmasters-staging.mydealertide.com), not
  # a deeper root (mhmasters.staging.mydealertide.com), because the zone is on a
  # Free plan and Universal SSL covers exactly one level of subdomain. A
  # two-level host would resolve and then fail TLS, which is a worse failure
  # than the one being fixed since it cannot be diagnosed from the app at all.
  #
  # Unset in production, where every method below is an identity function and
  # behaviour is byte for byte what it was.
  module SiteAddress
    module_function

    # @return [String] '' in production, '-staging' where configured
    def label_suffix
      ENV['PLATFORM_SITE_LABEL_SUFFIX'].to_s.strip.downcase
    end

    def root
      Brand.current.site_host_root.to_s.presence
    end

    # The label that appears in DNS for a stored subdomain.
    def label_for(subdomain)
      value = subdomain.to_s.presence
      return nil if value.blank?

      "#{value}#{label_suffix}"
    end

    # The stored subdomain a DNS label refers to, or nil when the label belongs
    # to a different environment.
    #
    # Rejecting an unsuffixed label when a suffix is configured is the whole
    # point: it means a staging deploy cannot serve a production-shaped
    # hostname even if a route were bound to it by hand.
    def subdomain_from_label(label)
      value = label.to_s.downcase.presence
      return nil if value.blank?

      suffix = label_suffix
      return value if suffix.blank?
      return nil unless value.end_with?(suffix)

      value.delete_suffix(suffix).presence
    end

    # @return [String, nil] the host a visitor would type, or nil when the site
    #   has no platform subdomain or no root is configured
    def host_for(website)
      host_for_subdomain(website&.subdomain)
    end

    # Takes a bare subdomain rather than a record, for the callers that hold a
    # previous value the record no longer has.
    def host_for_subdomain(subdomain)
      label = label_for(subdomain)
      site_root = root
      return nil if label.blank? || site_root.blank?

      "#{label}.#{site_root}"
    end
  end
end
