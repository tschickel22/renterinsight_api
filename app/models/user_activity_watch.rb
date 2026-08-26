# frozen_string_literal: true

# A platform-side flag on one user, capturing their request trail while active.
#
# Deliberately platform-only and invisible to the tenant. This is not a tenant
# feature and must never be surfaced through a tenant-facing endpoint.
#
# Known blind spot: capture happens in an ApplicationController after_action, so
# it sees only requests that reach a controller. A routing 404 never gets there,
# and neither does a request halted by a before_action rendering 403. Route
# probing and permission probing are therefore invisible here and still have to
# be read out of the Render request logs while those survive.
class UserActivityWatch < ApplicationRecord
  belongs_to :user
  belongs_to :company
  belongs_to :created_by, class_name: 'User', foreign_key: :created_by_user_id

  has_many :watched_requests, dependent: :delete_all

  validates :reason, presence: true

  scope :active, -> { where(active: true) }

  # Endpoints the frontend polls on a timer. Recorded but flagged, so a census
  # is not swamped by a browser tab someone left open. Reid's 60-per-hour
  # baseline was entirely useWorkqueueSummary's 60s interval.
  POLL_PATTERNS = [
    %r{/notifications/unread_count},
    %r{/settings/tenant_basic},
    %r{/report-ai/(suggested|usage)},
    %r{/workqueue/summary},
    %r{/health/ping},
    %r{/activity_logs/my_activity},
    %r{\A/cable}
  ].freeze

  # Cached per process with a short TTL. The request hook consults this on every
  # authenticated request, so it must never become a per-request query, and it
  # must not depend on a shared cache store being configured.
  CACHE_TTL = 30.seconds

  class << self
    def watched_user_ids
      if @cached_at.nil? || @cached_at < CACHE_TTL.ago
        @watched_ids = active.pluck(:user_id).to_set
        @cached_at   = Time.current
      end
      @watched_ids
    rescue StandardError => e
      # A watch lookup must never take the app down. Missing telemetry costs a
      # row; a raise here costs every request.
      Rails.logger.warn("[UserActivityWatch] lookup failed: #{e.message}")
      Set.new
    end

    def watching?(user_id)
      return false if user_id.nil?

      watched_user_ids.include?(user_id)
    end

    def active_for(user_id)
      active.find_by(user_id: user_id)
    end

    def reset_cache!
      @cached_at = nil
    end

    def poll_path?(path)
      POLL_PATTERNS.any? { |pattern| path.to_s.match?(pattern) }
    end
  end
end
