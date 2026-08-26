# frozen_string_literal: true

# Turns a watch's raw request trail into the two things that actually answer
# "what is this user doing": how fast they move, and what they open.
#
# This is the manual analysis from the 2026-08-26 Company 17 review, made
# repeatable. See the evidence archive referenced in that review for the worked
# example the thresholds came from.
class UserActivityReport
  # Reid's real sessions sat at a 17s median with a wide spread. An agent sweep
  # clusters under 2s with little variance. These are the buckets that separated
  # them, not a bright line: a slow agent and a fast human overlap, and the
  # report says so rather than pretending to a verdict.
  FAST_GAP_SECONDS = 2.0

  # A route opened once and never returned to. A tail of these is a product
  # tour rather than operational work.
  SINGLETON_THRESHOLD = 1

  def initialize(watch, since: nil, until_time: nil)
    @watch = watch
    @since = since
    @until = until_time
  end

  def as_json(*)
    {
      watch: watch_summary,
      totals: totals,
      cadence: cadence,
      route_census: route_census,
      busiest_hours: busiest_hours
    }
  end

  private

  attr_reader :watch

  def scope
    @scope ||= begin
      s = watch.watched_requests.chronological
      s = s.where('occurred_at >= ?', @since) if @since
      s = s.where('occurred_at <= ?', @until) if @until
      s
    end
  end

  def navigations
    @navigations ||= scope.navigations.to_a
  end

  def watch_summary
    {
      id: watch.id,
      user_id: watch.user_id,
      user_email: watch.user&.email,
      company_id: watch.company_id,
      company_name: watch.company&.name,
      reason: watch.reason,
      active: watch.active,
      started_at: watch.started_at,
      ended_at: watch.ended_at
    }
  end

  def totals
    all = scope.to_a
    {
      requests: all.size,
      navigations: navigations.size,
      background_polls: all.size - navigations.size,
      first_seen: all.first&.occurred_at,
      last_seen: all.last&.occurred_at,
      distinct_ips: all.map(&:ip_address).compact.uniq,
      distinct_user_agents: all.map(&:user_agent).compact.uniq
    }
  end

  # Gaps between consecutive navigations, polling excluded. Sub-500ms gaps are
  # dropped: those are the parallel fan-out of one screen loading, not a
  # decision to go somewhere.
  def cadence
    gaps = navigations.each_cons(2).map { |a, b| (b.occurred_at - a.occurred_at).to_f }
                      .select { |g| g > 0.5 && g < 600 }

    return { sample_size: 0, note: 'Not enough navigation to judge.' } if gaps.size < 5

    sorted = gaps.sort
    fast = gaps.count { |g| g < FAST_GAP_SECONDS }

    {
      sample_size: gaps.size,
      median_seconds: sorted[sorted.size / 2].round(1),
      mean_seconds: (gaps.sum / gaps.size).round(1),
      buckets: {
        'under_2s'  => fast,
        '2s_to_10s' => gaps.count { |g| g >= 2 && g < 10 },
        '10s_to_60s' => gaps.count { |g| g >= 10 && g < 60 },
        'over_60s'  => gaps.count { |g| g >= 60 }
      },
      fast_share: (fast.to_f / gaps.size).round(3),
      assessment: assessment(sorted[sorted.size / 2], fast.to_f / gaps.size)
    }
  end

  # Deliberately hedged. Request cadence can rule out fast automated extraction.
  # It cannot rule out a person using an AI assistant to decide where to click,
  # because a human in the loop produces human timing by definition.
  def assessment(median, fast_share)
    if median < FAST_GAP_SECONDS && fast_share > 0.6
      'Machine-paced. Sustained sub-2s navigation is not human reading.'
    elsif fast_share > 0.35
      'Mixed. Enough fast navigation to be worth reading the timeline directly.'
    else
      'Human-paced. Rules out fast automated extraction. Does not rule out a ' \
      'person acting on AI assistance, which produces human timing.'
    end
  end

  # The tail of once-opened routes is the signal. A CRM administrator opening
  # printed checks and journal entries exactly once each is touring the product.
  def route_census
    counts = Hash.new(0)
    navigations.each { |r| counts[normalise(r)] += 1 }

    ordered = counts.sort_by { |route, n| [-n, route] }
    singletons = ordered.select { |_, n| n <= SINGLETON_THRESHOLD }

    {
      distinct_routes: counts.size,
      singleton_count: singletons.size,
      singleton_share: counts.empty? ? 0.0 : (singletons.size.to_f / counts.size).round(3),
      routes: ordered.map { |route, n| { route: route, count: n } }
    }
  end

  def normalise(request)
    "#{request.http_method} #{request.path.to_s.split('?').first.gsub(%r{/\d+}, '/:id')}"
  end

  def busiest_hours
    scope.to_a.group_by { |r| r.occurred_at.utc.strftime('%Y-%m-%dT%H') }
         .transform_values(&:size)
         .sort_by { |hour, _| hour }
         .map { |hour, n| { hour: hour, requests: n } }
  end
end
