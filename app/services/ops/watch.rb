# frozen_string_literal: true

module Ops
  # Watches the servers from the inside (backlog E79). The outside watcher
  # (bin/uptime_watch, a Render cron job) covers the case where the server is
  # down and cannot say so itself.
  #
  # - booted!: each web server start. A start on the same code as the last one
  #   is a crash or a manual restart, not a release, and is reported.
  # - memory: a thread in the web server reads the container's memory every
  #   minute and reports above MEMORY_WARN, before it runs out and restarts.
  # - error!: each 500 is kept in server_errors; check! reports a spike.
  # - check!: every few minutes (OpsCheckJob): error spike, background jobs
  #   failing over and over, and the jobs heartbeat the outside watcher reads.
  module Watch
    module_function

    MEMORY_WARN = 0.85
    ERROR_SPIKE = 25          # server errors within CHECK_WINDOW
    JOB_FAILURES = 10         # failed background jobs within CHECK_WINDOW
    CHECK_WINDOW = 10.minutes
    KEEP_ERRORS = 30.days

    def service
      ENV['RENDER_SERVICE_NAME'].presence || "#{Rails.env}-web"
    end

    def booted!
      commit = ENV['RENDER_GIT_COMMIT'].presence
      last = ServerBoot.where(service: service).order(booted_at: :desc).first
      ServerBoot.create!(service: service, commit: commit, instance: ENV['RENDER_INSTANCE_ID'], booted_at: Time.current)
      return unless last && commit && last.commit == commit

      recent = ServerBoot.where(service: service, commit: commit).where(booted_at: 1.hour.ago..).count
      Alert.notify!('restart', 'the server restarted without a release',
                    "The web server restarted on the same code (#{commit.first(8)}) at #{Time.current.utc.strftime('%H:%M')} UTC, " \
                    "#{recent} #{'start'.pluralize(recent)} in the last hour. If nobody restarted it or changed its settings, it " \
                    'crashed, usually from running out of memory, and customers may have seen "server unavailable" for a ' \
                    'few minutes.', every: 15.minutes)
    rescue StandardError => e
      Rails.logger.error("[Ops::Watch] booted!: #{e.message}")
    end

    # The container's memory in use and its limit, in bytes (cgroup v2, then v1).
    def memory
      used, max = [%w[/sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.max],
                   %w[/sys/fs/cgroup/memory/memory.usage_in_bytes /sys/fs/cgroup/memory/memory.limit_in_bytes]]
                  .lazy.map { |u, m| [File.read(u).to_i, File.read(m).strip] rescue nil }.find(&:itself)
      return nil unless used && max&.match?(/\A\d+\z/) && max.to_i.positive? && max.to_i < 1 << 50

      { used: used, max: max.to_i }
    end

    def check_memory!
      m = memory or return
      share = m[:used].to_f / m[:max]
      return if share < MEMORY_WARN

      Alert.notify!('memory', "the server is at #{(share * 100).round}% of its memory",
                    "#{m[:used] / 1.megabyte} MB of #{m[:max] / 1.megabyte} MB in use. At 100% it restarts and customers " \
                    'lose it for a few minutes.')
    end

    def start_memory_watch
      return if @memory_watch&.alive?

      @memory_watch = Thread.new do
        loop do
          sleep 60
          Rails.application.executor.wrap { check_memory! }
        rescue StandardError => e
          Rails.logger.error("[Ops::Watch] memory: #{e.message}")
        end
      end
    end

    def error!(payload)
      exception = payload[:exception_object]
      status = payload[:status] || (exception && ActionDispatch::ExceptionWrapper.status_code_for_exception(exception.class.name))
      return unless status.to_i >= 500

      ServerError.create!(occurred_at: Time.current, request_method: payload[:method], path: payload[:path].to_s.first(500),
                          status: status, error_class: exception&.class&.name, message: exception&.message.to_s.first(1000),
                          request_id: payload[:request]&.request_id)
    rescue StandardError => e
      Rails.logger.error("[Ops::Watch] error!: #{e.message}")
    end

    def check!
      OpsMark.stamp!('heartbeat:jobs')
      errors = ServerError.where(occurred_at: CHECK_WINDOW.ago..)
      if (count = errors.count) >= ERROR_SPIKE
        top = errors.group(:error_class, :path).order(Arel.sql('count(*) desc')).limit(3).count
                    .map { |(klass, path), n| "#{n} x #{klass || 'error'} on #{path}" }
        Alert.notify!('errors', "#{count} server errors in #{CHECK_WINDOW.inspect}", "Most common: #{top.join('; ')}.")
      end

      failed = SolidQueue::FailedExecution.joins(:job).where(created_at: CHECK_WINDOW.ago..)
      if (count = failed.count) >= JOB_FAILURES
        top = failed.group('solid_queue_jobs.class_name').order(Arel.sql('count(*) desc')).limit(3).count
                    .map { |klass, n| "#{n} x #{klass}" }
        Alert.notify!('jobs', "#{count} background jobs failed in #{CHECK_WINDOW.inspect}", "Most common: #{top.join('; ')}.")
      end

      ServerError.where(occurred_at: ...KEEP_ERRORS.ago).in_batches.delete_all
    end
  end
end
