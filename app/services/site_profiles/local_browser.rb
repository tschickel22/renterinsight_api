# frozen_string_literal: true

module SiteProfiles
  # Headless Chrome, running in this container.
  #
  # Chosen over a hosted rendering service because the volume does not justify a
  # subscription: ten to twenty scans a month, at most ten pages each. The cost
  # is the other way round , Chrome lives in the image and takes memory from the
  # same box that serves the API, since Solid Queue runs inside Puma here.
  #
  # ONE browser per scan, not per page.
  #
  # A bot wall's cookie is per session. Booting a browser for each page would
  # re-solve Vercel's proof-of-work ten times over and take ten times as long,
  # so the session is held open across a scan and closed by the orchestrator
  # when the scan ends. Nothing memoizes it at class level: a Chrome left alive
  # in a web container is a leak that outlives the request that made it.
  class LocalBrowser
    CHROME_BIN = ENV.fetch('CHROME_BIN', '/usr/bin/chromium')
    CHROMEDRIVER_BIN = ENV.fetch('CHROMEDRIVER_BIN', '/usr/bin/chromedriver')

    PAGE_LOAD_TIMEOUT = 30
    # How long to keep waiting for a page to become readable — a challenge to
    # hand over the real site, and then a framework to draw it. The measured
    # clear on thehomeplus.com is about two seconds; hydration a moment after.
    SETTLE_TIMEOUT = 20
    POLL = 0.5

    # What "drawn" means. Both are needed: a Next.js page serves its streaming
    # payload as script long before any of it becomes markup, so the document is
    # already 700KB while holding no <a>, no <p> and no headings at all. Reading
    # it at that instant produced a five word profile of a site with 368.
    MIN_RENDERED_WORDS = 60
    MIN_RENDERED_LINKS = 3

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # A box with no browser must not pay a failed Chrome launch on every page of
    # a scan, so the first failure is remembered.
    def available?
      !@unavailable
    end

    # @return [String, nil] the DOM once the page has settled, or nil if it
    #   could not be loaded. Never raises: a scan carries on with what it had.
    def render(url)
      return nil unless available?

      driver.navigate.to(url)
      settle
      html = driver.page_source
      html.presence
    rescue StandardError => e
      @logger.warn("[SiteProfiles::LocalBrowser] #{url}: #{e.class}: #{e.message}")
      # A driver that has fallen over stays broken for every later page, so drop
      # it and let the next call start a fresh one.
      close
      nil
    end

    def close
      @driver&.quit
    rescue StandardError => e
      @logger.warn("[SiteProfiles::LocalBrowser] quit failed: #{e.class}: #{e.message}")
    ensure
      @driver = nil
    end

    private

    def driver
      @driver ||= begin
        d = Selenium::WebDriver.for(:chrome, **{ options: chrome_options, service: service }.compact)
        d.manage.timeouts.page_load = PAGE_LOAD_TIMEOUT
        d
      rescue StandardError => e
        # No browser here, or one Selenium cannot drive. Say so once and stop
        # trying: every later page in this scan would fail the same way and pay
        # the same launch timeout to find out.
        @unavailable = true
        @logger.warn("[SiteProfiles::LocalBrowser] no usable Chrome: #{e.class}: #{e.message}")
        raise
      end
    end

    # The container installs Debian's chromedriver at a known path. Anywhere
    # else , a developer's laptop , Selenium Manager finds a driver matching
    # whatever Chrome is installed, so passing no service is the right answer
    # rather than a broken path.
    def service
      return nil unless File.exist?(CHROMEDRIVER_BIN)

      Selenium::WebDriver::Chrome::Service.new(path: CHROMEDRIVER_BIN)
    end

    def chrome_options
      # Same reasoning as #service: an explicit binary in the image, and
      # Chrome's own default everywhere else.
      options = if File.exist?(CHROME_BIN)
                  Selenium::WebDriver::Chrome::Options.new(binary: CHROME_BIN)
                else
                  Selenium::WebDriver::Chrome::Options.new
                end
      [
        '--headless=new',
        # Required to run as root in a container, which is how the image runs.
        '--no-sandbox',
        # Render gives a container 64MB of /dev/shm and Chrome will exhaust it.
        '--disable-dev-shm-usage',
        '--disable-gpu',
        '--disable-extensions',
        '--mute-audio',
        '--window-size=1440,1200',
        # We read markup, never pixels: every image URL we want is an attribute
        # in the DOM. Not downloading them is most of the memory and most of the
        # time on a page of home photography.
        '--blink-settings=imagesEnabled=false'
      ].each { |arg| options.add_argument(arg) }

      # Chrome's own user agent with the word Headless removed. It is the same
      # engine either way; several bot walls refuse the headless string on
      # sight, which would leave us blocked while running a real browser.
      options.add_argument("--user-agent=#{USER_AGENT}")
      options
    end

    USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) ' \
                 'Chrome/131.0.0.0 Safari/537.36'

    # Wait for the page to be a page.
    #
    # Two things have to happen and neither is signalled by page load. A
    # checkpoint answers first, runs its proof-of-work and then replaces itself
    # with the real site. Then the framework has to draw that site: until it
    # does, page_source is a wall of streaming payload with no elements in it.
    #
    # Gives up quietly at the cap and lets the caller judge what it got — a
    # thin page that never grows is still worth what it says.
    def settle
      deadline = Time.current + SETTLE_TIMEOUT

      loop do
        break if Time.current >= deadline
        next sleep(POLL) if ArchiveFallback.challenged?(200, driver.page_source.to_s)
        break if rendered?

        sleep POLL
      end

      # Lazy content hangs below the fold on most dealer sites — galleries,
      # featured homes, the photography we want for a hero. One trip to the
      # bottom and back triggers it for the cost of a second.
      reveal_lazy_content
    end

    def rendered?
      stats = driver.execute_script(<<~JS)
        var text = document.body ? document.body.innerText.trim() : '';
        return {
          ready: document.readyState === 'complete',
          words: text ? text.split(/\s+/).length : 0,
          links: document.querySelectorAll('a[href]').length
        };
      JS

      stats['ready'] && stats['words'].to_i >= MIN_RENDERED_WORDS &&
        stats['links'].to_i >= MIN_RENDERED_LINKS
    rescue StandardError
      false
    end

    def reveal_lazy_content
      driver.execute_script('window.scrollTo(0, document.body.scrollHeight);')
      sleep POLL
      driver.execute_script('window.scrollTo(0, 0);')
    rescue StandardError
      nil
    end
  end
end
