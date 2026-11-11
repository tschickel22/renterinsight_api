require "puma/plugin"

# Runs Solid Queue inside Puma, like the gem's own `plugin :solid_queue`, with one
# difference: when the Solid Queue supervisor dies, this starts a new one instead of
# stopping Puma.
#
# Why: on staging (SOLID_QUEUE_IN_PUMA) a few seconds of database recovery made the
# supervisor raise PG::ConnectionBad while replacing a crashed fork. It exited, the
# gem's plugin then stopped Puma, and a short database blip became a full web restart
# (2026-10 to 2026-11, see project notes). Web requests ride out a blip on their own;
# only the job runner needs restarting.
#
# If the supervisor keeps dying (MAX_RESTARTS within RESTART_WINDOW) something is
# persistently wrong, so we fall back to the gem's behaviour and stop Puma, letting
# Render restart the whole service.
#
# Production does not use this: jobs run in their own worker service (bin/jobs).
Puma::Plugin.create do
  attr_reader :puma_pid, :solid_queue_pid, :log_writer

  RESTART_DELAYS = [5, 10, 20, 40, 60].freeze # seconds, last one repeats
  MAX_RESTARTS = 10
  RESTART_WINDOW = 15 * 60 # seconds

  def start(launcher)
    @log_writer = launcher.log_writer
    @puma_pid = $$
    @stopping = false
    @restarts = []

    in_background do
      monitor_solid_queue
    end

    launcher.events.on_booted { start_solid_queue }
    launcher.events.on_stopped { stop_solid_queue }
    launcher.events.on_restart { stop_solid_queue }
  end

  private
    def start_solid_queue
      @solid_queue_pid = fork do
        Thread.new { monitor_puma }
        SolidQueue::Supervisor.start
      end
    end

    def stop_solid_queue
      @stopping = true
      return unless solid_queue_pid

      Process.waitpid(solid_queue_pid, Process::WNOHANG)
      log "Stopping Solid Queue..."
      Process.kill(:INT, solid_queue_pid)
      Process.wait(solid_queue_pid)
    rescue Errno::ECHILD, Errno::ESRCH
    end

    def monitor_solid_queue
      loop do
        sleep 2
        next if @stopping || !solid_queue_dead?

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @restarts.select! { |t| now - t < RESTART_WINDOW }

        if @restarts.size >= MAX_RESTARTS
          log "Solid Queue died #{@restarts.size} times in #{RESTART_WINDOW / 60} minutes, stopping Puma..."
          Process.kill(:INT, $$)
          break
        end

        delay = RESTART_DELAYS[[@restarts.size, RESTART_DELAYS.size - 1].min]
        log "Solid Queue supervisor (pid #{solid_queue_pid}) has gone away, restarting it in #{delay}s..."
        @restarts << now
        sleep delay
        next if @stopping

        start_solid_queue
        log "Solid Queue supervisor restarted (pid #{solid_queue_pid})"
      end
    end

    def monitor_puma
      loop do
        if Process.ppid != puma_pid
          log "Detected Puma has gone away, stopping Solid Queue..."
          Process.kill(:INT, $$)
          break
        end
        sleep 2
      end
    end

    # True once the forked supervisor has exited (and reaps it so it is not a zombie).
    def solid_queue_dead?
      return false unless solid_queue_pid

      !Process.waitpid(solid_queue_pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD, Errno::ESRCH
      true
    end

    def log(...)
      log_writer.log(...)
    end
end
