# frozen_string_literal: true

# Emails the installer admin a dealer invited to link (E68 step 5b).
class CompanyLinkInviteEmailJob < ApplicationJob
  queue_as :default

  def perform(link_id)
    link = CompanyLink.find_by(id: link_id)
    CompanyLinkNotifier.invite_email(link) if link&.invited?
  end
end
