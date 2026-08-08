# frozen_string_literal: true

# Grades a previously scanned site in the background.
#
# Fetching ten pages from someone else's server takes longer than a request
# should wait, and the admin does not need to watch it happen: the button
# reports that it started and the row picks up the report on the next refresh.
class SiteProfileAuditJob < ApplicationJob
  queue_as :default

  def perform(profile_id)
    profile = SiteContentProfile.find_by(id: profile_id)
    return if profile.nil?

    SiteProfiles::AuditRunner.new(profile).call
  end
end
