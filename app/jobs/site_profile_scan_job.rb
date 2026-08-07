# frozen_string_literal: true

# A crawl plus an LLM pass takes minutes, so scanning runs off the request.
# The admin UI polls the profile's status.
class SiteProfileScanJob < ApplicationJob
  queue_as :default

  # Retrying a scan re-fetches the whole site and re-bills the model, so a
  # failed scan stays failed and visible rather than silently retrying.
  discard_on StandardError do |job, error|
    profile = SiteContentProfile.find_by(id: job.arguments.first)
    profile&.update(status: 'failed', error_message: error.message.truncate(500))
    Rails.logger.error("[SiteProfileScanJob] profile=#{job.arguments.first} failed: #{error.class}: #{error.message}")
  end

  def perform(profile_id)
    profile = SiteContentProfile.find(profile_id)

    # Same job, same status machine, same discard-on-failure policy — only the
    # extraction differs. A document has no site to crawl, no robots.txt to
    # respect and no links to follow, so it gets its own orchestrator rather
    # than an `if` threaded through every step of the crawl.
    if profile.document?
      SiteProfiles::DocumentOrchestrator.new(profile).call
    else
      SiteProfiles::Orchestrator.new(profile).call
    end
  end
end
