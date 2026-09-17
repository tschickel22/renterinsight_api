# frozen_string_literal: true

# Reports at boot whether jemalloc is the allocator, and stops it spreading to
# child programs.
#
# The Dockerfile CMD preloads jemalloc through LD_PRELOAD. There is no shell on
# the Render instance to check that from, so this line in the boot log is the
# confirmation: "[Allocator] jemalloc loaded" or "[Allocator] jemalloc NOT
# loaded". Production ran without it from 2025-10-23 to 2026-09-17 and nothing
# said so.
#
# Once this process has jemalloc mapped, LD_PRELOAD has done its job. Puma
# workers and the Solid Queue processes are forked from here, so they inherit
# the loaded allocator without the variable. Removing it keeps jemalloc out of
# programs the app launches: Chromium brings its own allocator, and pdftoppm,
# qpdf, tesseract and LibreOffice gain nothing from ours.
#
# Linux only: /proc does not exist on a developer's Mac, so this is a no-op there.
if File.exist?('/proc/self/maps')
  jemalloc_loaded = begin
    File.foreach('/proc/self/maps').any? { |line| line.include?('jemalloc') }
  rescue StandardError
    false
  end

  if jemalloc_loaded
    Rails.logger.info('[Allocator] jemalloc loaded')
    ENV.delete('LD_PRELOAD') if ENV['LD_PRELOAD'].to_s.include?('jemalloc')
  else
    Rails.logger.warn('[Allocator] jemalloc NOT loaded, running on glibc malloc')
  end
end
