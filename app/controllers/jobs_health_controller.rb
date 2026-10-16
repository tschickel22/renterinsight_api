# frozen_string_literal: true

# GET /up/jobs: 200 while background jobs are running (OpsCheckJob checked in
# within STALE_AFTER), 503 when they have stopped. Read by the outside watcher
# (bin/uptime_watch). Says nothing else, so it needs no sign-in.
class JobsHealthController < ActionController::API
  STALE_AFTER = 15.minutes

  def show
    at = OpsMark.at('heartbeat:jobs')
    head(at && at > STALE_AFTER.ago ? :ok : :service_unavailable)
  end
end
