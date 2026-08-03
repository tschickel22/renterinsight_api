# frozen_string_literal: true

# Rebuilds the cached national directory of Timber Creek Housing retailers that
# backs the "Add Timber Creek Dealer" picker.
#
# This MUST stay a background job: the crawl walks ~14 state pages with a
# politeness delay between them, which is far longer than any web request should
# live. The admin endpoint enqueues this and reads the cache.
class TimberCreekDirectoryRefreshJob < ApplicationJob
  queue_as :default

  def perform
    entries = Catalog::TimberCreekDealerDirectory.refresh!
    Rails.logger.info "[TimberCreekDirectoryRefreshJob] cached #{entries.size} retailers"
  end
end
