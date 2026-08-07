# frozen_string_literal: true

# Keeps a site's Worker route in step with its subdomain.
#
# Runs in the background because it is a third-party HTTP call on the path of
# an ordinary save: a Cloudflare timeout must not turn "rename my site" into a
# failed request. The route is what makes the subdomain reachable at all, so a
# transient failure is worth retrying rather than dropping.
#
# Ordering matters when a subdomain is renamed. The old route is deleted first
# so the two never overlap, and a failed delete does not stop the create — an
# orphaned route is untidy, an absent one is a broken site.
class WebsiteSubdomainRouteJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  # @param website_id [Integer]
  # @param previous_host [String, nil] host to unbind first, on a rename
  def perform(website_id, previous_host = nil)
    Websites::SubdomainRouteProvisioner.remove(previous_host) if previous_host.present?

    website = Website.find_by(id: website_id)
    return if website.nil?
    # A deleted site keeps its row; its subdomain should stop answering.
    return if website.is_deleted?

    Websites::SubdomainRouteProvisioner.ensure(website)
  end
end
