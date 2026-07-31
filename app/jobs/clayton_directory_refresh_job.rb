# frozen_string_literal: true

# Rebuilds the cached national directory of Clayton home centers that backs the
# "Add Clayton Dealer" picker.
#
# This MUST stay a background job: the crawl walks ~43 state index pages with a
# politeness delay between them, which is far longer than any web request should
# live. The admin endpoint enqueues this and reads the cache.
class ClaytonDirectoryRefreshJob < ApplicationJob
  queue_as :default

  def perform
    entries = Catalog::ClaytonHomeCenterDirectory.refresh!
    Rails.logger.info "[ClaytonDirectoryRefreshJob] cached #{entries.size} home centers"
  end
end
