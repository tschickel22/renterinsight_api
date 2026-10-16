# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]

# ── Memory Management (Production) ─────────────────────────────────────
# puma_worker_killer restarts the largest worker (one at a time, so nobody
# notices) when the web server's processes together pass 90% of `ram`.
# `ram` is the container's own memory limit (2 GB on Render Standard), read
# from cgroups; PWK_RAM overrides it. It was hard-coded for the 512 MB Starter
# plan, which no longer matches the plan in use.
container_mb = [ "/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes" ].filter_map do |path|
  bytes = File.read(path).strip
  bytes.to_i / (1024 * 1024) if bytes.match?(/\A\d+\z/) && bytes.to_i < (1 << 50)
rescue StandardError
  nil
end.first

if ENV.fetch("RAILS_ENV", "development") != "development"
  workers ENV.fetch("WEB_CONCURRENCY", 2).to_i
  preload_app!

  before_fork do
    # Properly disconnect before forking
    ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord)
  end

  before_worker_boot do
    ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
  end

  # Auto-restart workers that grow too large, checked every 30 seconds
  # Rolling restart (one worker at a time) to avoid downtime
  begin
    require 'puma_worker_killer'
    PumaWorkerKiller.config do |config|
      config.ram           = (ENV.fetch("PWK_RAM", "").empty? ? (container_mb || 480) : ENV["PWK_RAM"]).to_i # MB
      config.frequency     = 30                               # Check every 30 seconds
      config.percent_usage = 0.90                              # Restart at 90% of ram limit
      config.rolling_restart_frequency = 6 * 3600              # Rolling restart every 6 hours
      config.reaper_status_logs = false                        # Reduce log noise
    end
    PumaWorkerKiller.start
  rescue LoadError
    # puma_worker_killer not available (dev environment)
  end

  # Server watch (backlog E79): record this start (a start on the same code is
  # a crash, and is reported) and watch the container's memory.
  after_booted do
    Thread.new do
      Rails.application.executor.wrap { Ops::Watch.booted! }
    end
    Ops::Watch.start_memory_watch
  end
end
