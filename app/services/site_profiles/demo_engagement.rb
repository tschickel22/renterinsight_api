# frozen_string_literal: true

module SiteProfiles
  # What happened after a demo link was sent.
  #
  # Written for the question a rep actually asks before following up: did they
  # open it, how many times, when was the last time, and which design did they
  # keep going back to. That last one is the reason to build this rather than a
  # hit counter, because it turns a follow-up call from "did you get a chance to
  # look" into "you kept coming back to Coastal Living, shall we start there".
  class DemoEngagement
    # Enough of a gap to mean they came back rather than kept the tab open.
    RETURN_GAP = 30.minutes

    def initialize(profile)
      @profile = profile
    end

    def call
      {
        opens: sessions.count,
        viewers: sessions.distinct.count(:visitor_token),
        first_opened_at: sessions.minimum(:first_seen_at)&.iso8601,
        last_opened_at: sessions.maximum(:last_seen_at)&.iso8601,
        returning_viewers: returning_viewers,
        # Ours, counted separately rather than dropped: "the prospect never
        # opened it" and "nobody opened it" are different conversations.
        internal_opens: internal.count,
        designs: designs,
        sessions: recent_sessions
      }
    end

    private

    def sessions
      @sessions ||= @profile.site_profile_views.external
    end

    def internal
      @internal ||= @profile.site_profile_views.internal
    end

    # Someone who came back in a later session. The signal a rep wants: one
    # visit is curiosity, three is a shortlist.
    def returning_viewers
      sessions.group(:visitor_token).count.count { |_, sessions_count| sessions_count > 1 }
    end

    # Designs ranked by how much of the viewer's attention they held.
    def designs
      tally = Hash.new(0)
      sessions.pluck(:templates_viewed).each do |viewed|
        viewed.to_h.each { |template_id, count| tally[template_id] += count.to_i }
      end

      tally.sort_by { |_, count| -count }.map { |template_id, count| { template_id: template_id, views: count } }
    end

    # The individual visits, newest first, so a rep can see the pattern rather
    # than only the totals: three opens on one afternoon reads differently from
    # three across a fortnight.
    def recent_sessions
      sessions.order(last_seen_at: :desc).limit(25).map do |view|
        {
          first_seen_at: view.first_seen_at&.iso8601,
          last_seen_at: view.last_seen_at&.iso8601,
          duration_seconds: view.duration_seconds,
          view_events: view.view_events,
          device_type: view.device_type,
          referrer: view.referrer,
          designs: view.templates_viewed.to_h.keys
        }
      end
    end
  end
end
