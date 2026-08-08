# frozen_string_literal: true

# One prospect's session with a demo link we sent them.
#
# Answers the question a rep has after sending a preview: did they open it, how
# often, and which design did they keep going back to. An interested prospect
# and a silent one look identical until this exists.
class SiteProfileView < ApplicationRecord
  belongs_to :site_content_profile

  scope :external, -> { where(is_internal: false) }
  scope :internal, -> { where(is_internal: true) }
  scope :in_window, ->(from, to) { where(first_seen_at: from..to) }

  # Records one beat of a session, creating it on first sight and touching it
  # after that.
  #
  # Upsert rather than find-then-create: the showcase fires on first paint and
  # again on the first design change, which on a fast connection can race, and
  # the unique index would turn that race into a 500 on a prospect's screen.
  def self.record!(profile:, session_token:, visitor_token:, template_id: nil, attributes: {})
    return nil if profile.nil? || session_token.blank? || visitor_token.blank?

    now = Time.current
    view = find_or_create_by!(site_content_profile_id: profile.id, session_token: session_token) do |v|
      v.visitor_token = visitor_token
      v.first_seen_at = now
      v.last_seen_at = now
      v.referrer = attributes[:referrer]
      v.device_type = attributes[:device_type]
      v.ip_hash = attributes[:ip_hash]
      v.is_internal = attributes[:is_internal].present?
    end

    view.touch_view!(template_id: template_id, at: now)
    view
  rescue ActiveRecord::RecordNotUnique
    # Lost the race; the winner's row is the one to update.
    retry_view = find_by(site_content_profile_id: profile.id, session_token: session_token)
    retry_view&.touch_view!(template_id: template_id, at: Time.current)
    retry_view
  end

  def touch_view!(template_id: nil, at: Time.current)
    tally = templates_viewed.to_h
    tally[template_id.to_s] = tally[template_id.to_s].to_i + 1 if template_id.present?

    update!(last_seen_at: at, view_events: view_events.to_i + 1, templates_viewed: tally)
  end

  # Time between the first and last beat of the session. Not a precise dwell
  # time, since the last beat is whenever they last changed something, but it
  # separates a glance from a read.
  def duration_seconds
    return 0 if first_seen_at.blank? || last_seen_at.blank?

    (last_seen_at - first_seen_at).round
  end
end
