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

    ENV['SITE_SCAN_RENDERER'] ||= 'chrome'

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
  # Two kinds of credential work, and one of them is much better here.
  #
  #   An API KEY (ri_live_...) from Settings, carrying websites:write. It does
  #   not expire, so a workflow that runs whenever a prospect turns up keeps
  #   working. Preferred.
  #
  #   A browser login (eyJ...), copied from the app you are pushing to:
  #   DevTools, Application, Local Storage, authToken. Fine for a one-off, but
  #   it dies after 7 days.
  #
  # Either belongs to the host it came from — one from staging pushed at
  # production is a 401.
  #
  # Put it in .env as SITE_SCAN_PUSH_TOKEN (dotenv is loaded in development, so
  # the task picks it up), or pass TOKEN= inline for a one-off. A platform-level
  # API key also needs COMPANY_ID, to say which tenant owns the demo.
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

        It comes from DealerTide, not from this machine. Either:

          an API key from Settings carrying websites:write (starts ri_live_,
          never expires — the better one for this), or

          your browser login: sign in to #{app}, DevTools,
          Application, Local Storage, copy authToken (lasts 7 days).

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

    # The entire point of this task is to render locally, so it does not also
    # require someone to remember a switch. Without it the scan silently falls
    # back to a plain fetch and gives up on exactly the sites this exists for.
    ENV['SITE_SCAN_RENDERER'] ||= 'chrome'

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
        abort("push refused (401). Expired, revoked, or issued by a host other than #{app}.")
      when 403
        abort("push refused (403). #{response.body.to_s[0, 200]}")
      else
        abort("push failed: HTTP #{response.code} #{response.body.to_s[0, 300]}")
      end
    end

    remote = JSON.parse(response.body)
    # The local copy has done its job; the shareable one lives on the server.
    profile.destroy

    puts "\ndone. #{app}/preview/templates/#{remote['preview_token']}"
  end

  # Is the credential good, before spending six minutes finding out?
  #
  # A scan runs a browser over ten pages and calls a model before the push is
  # even attempted, so a credential problem surfaces at the very end. This asks
  # the same question in one request, and creates nothing: the body is
  # deliberately incomplete, so a credential that works answers 422 for the
  # missing profile rather than storing a demo.
  #
  #   rake site_scan:check
  desc 'Check the push credential and target without scanning anything'
  task check: :environment do
    target = ENV.fetch('TARGET', 'https://renterinsight-api-staging.onrender.com').chomp('/')
    token = ENV['SITE_SCAN_PUSH_TOKEN'].presence || ENV['TOKEN'].presence
    abort('No token. See rake site_scan:push for where it comes from.') if token.blank?

    kind = if token.start_with?('ri_') then 'API key (does not expire)'
           elsif token.start_with?('eyJ') then 'browser login (expires after 7 days)'
           else 'unrecognised — expected ri_live_... or eyJ...'
           end
    puts "credential: #{kind}"
    puts "target:     #{target}"

    uri = URI.join("#{target}/", 'api/v1/site_content_profiles/import')
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{token}"
    request['X-Company-ID'] = ENV['COMPANY_ID'] if ENV['COMPANY_ID'].present?
    request.body = {}.to_json

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 60
    response = http.request(request)

    puts case response.code.to_i
         when 422 then 'ready. The credential was accepted and nothing was created.'
         when 401 then 'refused: expired, revoked, or issued by a different host.'
         when 400 then 'refused: platform-level API key. Add COMPANY_ID to name the tenant.'
         when 403 then "refused: #{response.body.to_s[0, 160]}"
         when 404 then 'the target has not deployed the import endpoint yet.'
         else "unexpected HTTP #{response.code}: #{response.body.to_s[0, 160]}"
         end
  end
end
