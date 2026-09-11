# frozen_string_literal: true

# Shared by site_scan:check and the pre-flight inside site_scan:push.
module SiteScanTasks
  module_function

  # One request that creates nothing: the body is deliberately incomplete, so a
  # credential that works answers 422 for the missing profile.
  #
  # @return [String, nil] what is wrong, or nil when the credential is good.
  def credential_problem(target:, token:, company_id: nil)
    uri = URI.join("#{target}/", 'api/v1/site_content_profiles/import')
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{token}"
    request['X-Company-ID'] = company_id if company_id.present?
    request.body = {}.to_json

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 60
    response = http.request(request)

    case response.code.to_i
    when 422 then nil
    when 401 then "refused by #{target}: expired, revoked, or issued by a different host."
    when 400 then "refused by #{target}: platform-level API key. Add COMPANY_ID to name the tenant."
    when 403 then "refused by #{target}: #{response.body.to_s[0, 160]}"
    when 404 then "#{target} has not deployed the import endpoint yet."
    else "unexpected HTTP #{response.code} from #{target}: #{response.body.to_s[0, 160]}"
    end
  rescue StandardError => e
    "could not reach #{target}: #{e.class}: #{e.message}"
  end

  # Demo management from a machine: the same credential the push uses.
  def request_json(method, target, path, token, body: nil, company_id: nil)
    uri = URI.join("#{target}/", path)
    request = case method
              when :get   then Net::HTTP::Get.new(uri)
              when :post  then Net::HTTP::Post.new(uri)
              when :patch then Net::HTTP::Patch.new(uri)
              end
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{token}"
    request['X-Company-ID'] = company_id if company_id.present?
    request.body = body.to_json if body

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 60
    response = http.request(request)
    raise "HTTP #{response.code}: #{response.body.to_s[0, 200]}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def describe(token)
    if token.start_with?('ri_') then 'API key (does not expire)'
    elsif token.start_with?('eyJ') then 'browser login (expires after 7 days)'
    else 'unrecognised — expected ri_live_... or eyJ...'
    end
  end
end

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
  # COMPANY_ID decides WHOSE Demo Sites list it appears in, and is usually the
  # thing you actually want to set: a platform-level key defaults to its own
  # owner's tenant, so a demo built for a client lands somewhere that client
  # cannot see. rake site_scan:lots prints the ids. LOT sets the inventory lot
  # the demo borrows, and defaults to the same tenant.
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

    # Say where this is going BEFORE spending six minutes getting there. TARGET
    # defaults to staging, so a production credential with no TARGET set scans
    # for six minutes and then 401s against the wrong host — which is exactly
    # what happened.
    puts "target: #{target}"
    problem = SiteScanTasks.credential_problem(target: target, token: token,
                                               company_id: ENV['COMPANY_ID'])
    abort("#{problem}\n\nNothing was scanned.") if problem

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

    # Which client's Demo Sites list it went into, not just that it worked.
    # A platform-level key defaults to its owner's tenant, so a demo built for a
    # client can land in the wrong list and be invisible to the person who
    # wanted to build a site from it. Set COMPANY_ID to choose, and
    # rake site_scan:lots prints the ids.
    where = remote['company_name'] || "company #{remote['company_id']}"
    puts "\nadded to Demo Sites for #{where}"
    puts "#{app}/preview/templates/#{remote['preview_token']}"
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

    puts "credential: #{SiteScanTasks.describe(token)}"
    puts "target:     #{target}"

    problem = SiteScanTasks.credential_problem(target: target, token: token,
                                               company_id: ENV['COMPANY_ID'])
    puts problem || 'ready. The credential was accepted and nothing was created.'
  end

  # Which lots a demo can borrow inventory from, with the ids the next task
  # wants. Only lots that would actually render: public inventory on, a token
  # issued, and homes to show.
  #
  #   rake site_scan:lots
  desc 'List the inventory lots a demo can be pointed at'
  task lots: :environment do
    target = ENV.fetch('TARGET', 'https://renterinsight-api-staging.onrender.com').chomp('/')
    token = ENV['SITE_SCAN_PUSH_TOKEN'].presence || ENV['TOKEN'].presence
    abort('No token. See rake site_scan:push.') if token.blank?

    data = SiteScanTasks.request_json(:get, target, 'api/v1/site_content_profiles/inventory_lots',
                                      token, company_id: ENV['COMPANY_ID'])
    data['items'].each { |lot| puts format('  %-6s %-40s %s homes', lot['id'], lot['name'], lot['home_count']) }
  end

  # Change which designs a demo offers, and which lot it shows, WITHOUT
  # rescanning. The link stays the same, which is the point: it may already be
  # in a prospect's inbox.
  #
  #   TEMPLATES=cedar-ridge-community,coastal-living LOT=47 \
  #     rake "site_scan:configure[<preview token>]"
  desc 'Set the designs and inventory lot on an existing demo'
  task :configure, [:preview_token] => :environment do |_t, args|
    preview_token = args[:preview_token].presence || abort('usage: rake "site_scan:configure[<preview token>]"')
    target = ENV.fetch('TARGET', 'https://renterinsight-api-staging.onrender.com').chomp('/')
    token = ENV['SITE_SCAN_PUSH_TOKEN'].presence || ENV['TOKEN'].presence
    abort('No token. See rake site_scan:push.') if token.blank?

    templates = (ENV['TEMPLATES'] || '').split(',').map(&:strip).reject(&:empty?)
    lot = ENV['LOT'].presence
    abort('Nothing to change. Set TEMPLATES and/or LOT.') if templates.empty? && lot.nil?

    listing = SiteScanTasks.request_json(:get, target, 'api/v1/site_content_profiles',
                                         token, company_id: ENV['COMPANY_ID'])
    demo = listing['items'].find { |item| item['preview_token'] == preview_token }
    abort("No demo on #{target} with that preview token.") if demo.nil?

    body = {}
    body[:preview_template_ids] = templates if templates.any?
    body[:inventory_company_id] = lot if lot

    updated = SiteScanTasks.request_json(:patch, target,
                                         "api/v1/site_content_profiles/#{demo['id']}",
                                         token, body: body, company_id: ENV['COMPANY_ID'])

    puts "updated #{updated['display_name']}"
    puts "  designs:   #{Array(updated['preview_template_ids']).size} offered"
    puts "  inventory: company #{updated['inventory_company_id'] || '(resolver default)'}"
    puts "  link unchanged"
  end

  # Copy an existing demo into another tenant's Demo Sites list.
  #
  # A demo lands in whichever tenant the credential named, and a platform-level
  # key defaults to its owner's — so a demo built for a client can end up in the
  # wrong list, invisible to the person who wants to build a site from it.
  #
  # This re-imports the profile that already exists rather than crawling again:
  # same content, no six minute scan, no second trip to the client's site. The
  # original is left alone.
  #
  #   COMPANY_ID=21 rake "site_scan:clone[<preview token>]"
  desc "Copy an existing demo into another tenant's demo list"
  task :clone, [:preview_token] => :environment do |_t, args|
    preview_token = args[:preview_token].presence || abort('usage: rake "site_scan:clone[<preview token>]"')
    target = ENV.fetch('TARGET', 'https://renterinsight-api-staging.onrender.com').chomp('/')
    token = ENV['SITE_SCAN_PUSH_TOKEN'].presence || ENV['TOKEN'].presence
    abort('No token. See rake site_scan:push.') if token.blank?
    company_id = ENV['COMPANY_ID'].presence || abort('COMPANY_ID is required — which tenant should own it. rake site_scan:lots lists them.')

    # Read from the authenticated detail rather than the public preview.
    #
    # The public payload is deliberately narrow — it carries what a browser
    # needs to RENDER a demo, and not its provenance. Copying from it produced a
    # profile with no source_url, which the model rejects for a scanned demo,
    # and the import answered 422 with nothing to read.
    listing = SiteScanTasks.request_json(:get, target, 'api/v1/site_content_profiles',
                                         token, company_id: ENV['SOURCE_COMPANY_ID'].presence)
    demo = listing['items'].find { |item| item['preview_token'] == preview_token }
    abort("No demo on #{target} with that preview token. SOURCE_COMPANY_ID names the tenant it is in now.") if demo.nil?

    source = SiteScanTasks.request_json(:get, target,
                                        "api/v1/site_content_profiles/#{demo['id']}", token,
                                        company_id: ENV['SOURCE_COMPANY_ID'].presence)

    body = {
      source_url: source['source_url'],
      display_name: source['display_name'],
      profile: source['profile'],
      report: source['report'],
      seo_report: source['seo_report'],
      schema_version: source['schema_version'],
      suggested_subdomain: source['suggested_subdomain'],
      preview_template_ids: source['preview_template_ids'] || [],
      inventory_company_id: ENV['LOT'].presence || company_id
    }.compact

    created = SiteScanTasks.request_json(:post, target, 'api/v1/site_content_profiles/import',
                                         token, body: body, company_id: company_id)

    app = target.include?('staging') ? 'https://staging.dealertide.com' : 'https://app.dealertide.com'
    puts "copied #{created['display_name']} into #{created['company_name'] || "company #{company_id}"}"
    puts "  #{app}/preview/templates/#{created['preview_token']}"
    puts '  it is now in that client\'s Demo Sites list, ready for Use This Design'
  end
end
