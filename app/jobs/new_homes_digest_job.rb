# frozen_string_literal: true

# Daily notice to the platform admins of what the feeds brought in
# (Truebuild::NewHomes). Scheduled after the overnight crawls.
class NewHomesDigestJob < ApplicationJob
  queue_as :low

  def perform
    Truebuild::NewHomes.digest!
  end
end
