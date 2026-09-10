# frozen_string_literal: true

namespace :site_scan do
  # Answers one question that cannot be answered from a laptop: what happens
  # when THIS server tries to read a site.
  #
  # A bot check clears in 1.2 seconds on an M5 and its proof-of-work is CPU
  # bound, so a shared container vCPU can take tens of times longer, and a
  # datacenter address may be refused outright however long it waits. Those look
  # identical from outside and want opposite answers — wait longer, or pay for a
  # renderer with residential egress.
  #
  #   bundle exec rake "site_scan:probe[https://thehomeplus.com]"
  desc 'Report how this server fares fetching and rendering a URL'
  task :probe, [:url] => :environment do |_t, args|
    url = args[:url].presence || abort('usage: rake "site_scan:probe[https://example.com]"')

    puts "probing #{url}"
    puts "renderer: #{SiteProfiles::Renderer.provider || 'off'} (enabled=#{SiteProfiles::Renderer.enabled?})"
    puts "challenge budget: #{SiteProfiles::LocalBrowser::CHALLENGE_WAIT}s"

    plain = Net::HTTP.get_response(URI.parse(url))
    puts "\nplain fetch: HTTP #{plain.code}"
    %w[server x-vercel-mitigated cf-mitigated x-vercel-id].each do |header|
      puts "  #{header}: #{plain[header]}" if plain[header]
    end
    puts "  challenged: #{SiteProfiles::ArchiveFallback.challenged?(plain.code.to_i, plain.body.to_s)}"

    browser = SiteProfiles::LocalBrowser.new
    started = Time.current
    html = browser.render(url)
    elapsed = (Time.current - started).round(1)

    puts "\nbrowser: #{browser.available? ? 'started' : 'DID NOT START'}"
    puts "  #{browser.diagnostic}" if browser.diagnostic
    puts "  elapsed: #{elapsed}s"
    if html
      still = SiteProfiles::ArchiveFallback.challenged?(200, html)
      doc = Nokogiri::HTML(html)
      puts "  still challenged: #{still}"
      puts "  title: #{doc.title}"
      puts "  links: #{doc.css('a[href]').size}  paragraphs: #{doc.css('p').size}"
    else
      puts '  returned nothing'
    end
    browser.close

    puts "\nverdict: #{html && !SiteProfiles::ArchiveFallback.challenged?(200, html) ? 'this server can read the site' : 'this server cannot read the site'}"
  end

  # Scan here, share there.
  #
  # For a prospect whose site refuses the server. Measured on thehomeplus.com:
  # a bot check that never clears in 120s from Render clears in 0.1s from a
  # laptop on a home connection, with the same browser build — the address is
  # what is being refused, so the only fixes are to pay for residential egress
  # or to scan from somewhere that already has it. This is the second one.
  #
  # The whole scan runs locally, against this same code, and only the finished
  # profile is sent up. Images were already rehosted onto S3 during the scan, so
  # they load from anywhere.
  #
  #   TOKEN=... rake "site_scan:push[https://theirsite.com]"
  #   TOKEN=... TARGET=https://renterinsight-api-prod.onrender.com \
  #     rake "site_scan:push[https://theirsite.com,Their Label]"
  #
  # The token is YOUR DEALERTIDE LOGIN, not anything on this machine: open the
  # app you are pushing to, DevTools, Application, Local Storage, authToken. It
  # is a platform-admin bearer token and lasts 7 days, and it belongs to the
  # host it came from — a staging token pushed at production is a 401.
  #
  # Put it in .env as SITE_SCAN_PUSH_TOKEN (dotenv is loaded in development, so
  # the task picks it up), or pass TOKEN= inline for a one-off.
  #
  # COMPANY_ID sets which tenant owns the demo (defaults to the token's own
  # company). LOT sets the inventory lot the demo borrows.
  desc 'Scan a site locally and push the finished profile to staging or production'
  task :push, %i[url label] => :environment do |_t, args|
    url = args[:url].presence || abort('usage: rake "site_scan:push[https://example.com]"')
    target = ENV.fetch('TARGET', 'https://renterinsight-api-staging.onrender.com').chomp('/')
    # Where a human signs in, which is not where the API lives. The token is
    # copied from the browser, so the message has to name the address the
    # browser knows.
    app = target.include?('staging') ? 'https://staging.dealertide.com' : 'https://app.dealertide.com'
    token = ENV['SITE_SCAN_PUSH_TOKEN'].presence || ENV['TOKEN'].presence
    if token.blank?
      abort(<<~TEXT)
        No push token.

        It comes from DealerTide, not from this machine: sign in to
        #{app}, open DevTools, Application, Local Storage, and copy
        authToken. It lasts 7 days.

        Then either put it in this repo's .env:

            SITE_SCAN_PUSH_TOKEN=eyJhbGci...

        or pass it for one run:

            TOKEN=eyJhbGci... rake "site_scan:push[#{url}]"
      TEXT
    end

    company = Company.find_by(id: ENV['LOCAL_COMPANY_ID']) || Company.first
    abort('no company in the local database to scan under') if company.nil?

    profile = SiteContentProfile.new(company: company, source_url: url, status: 'pending',
                                     display_name: args[:label].presence)
    profile.save!(validate: false)

    puts "scanning #{url} locally (this takes a few minutes)"
    started = Time.current
    begin
      SiteProfiles::Orchestrator.new(profile).call
    rescue StandardError => e
      profile.destroy
      abort("scan failed: #{e.message}")
    end
    profile.reload
    puts "  read #{profile.report['page_count']} pages in #{(Time.current - started).round}s"
    puts "  brand: #{profile.profile.dig('brand', 'name').inspect}"
    puts "  logo:  #{profile.profile.dig('brand', 'logo_url').present? ? 'found' : 'none'}"

    body = {
      source_url: profile.source_url,
      display_name: profile.display_name,
      profile: profile.profile,
      report: profile.report,
      seo_report: profile.seo_report,
      schema_version: profile.schema_version,
      suggested_subdomain: profile.suggested_subdomain,
      robots_allowed: profile.robots_allowed,
      preview_template_ids: (ENV['TEMPLATES'] || '').split(',').map(&:strip).reject(&:blank?),
      inventory_company_id: ENV['LOT'].presence
    }.compact

    uri = URI.join("#{target}/", 'api/v1/site_content_profiles/import')
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{token}"
    request['X-Company-ID'] = ENV['COMPANY_ID'] if ENV['COMPANY_ID'].present?
    request.body = body.to_json

    puts "pushing to #{target}"
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 60
    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      # The two failures worth naming, because the body does not explain either:
      # a token is bound to the host that issued it and expires after a week.
      case response.code.to_i
      when 401
        abort("push refused (401). That token is expired, or it came from a different host than #{app}.")
      when 403
        abort('push refused (403). That login is not a platform admin on the target.')
      else
        abort("push failed: HTTP #{response.code} #{response.body.to_s[0, 300]}")
      end
    end

    remote = JSON.parse(response.body)
    # The local copy has done its job; the shareable one lives on the server.
    profile.destroy

    puts "\ndone. #{app}/preview/templates/#{remote['preview_token']}"
  end
end
