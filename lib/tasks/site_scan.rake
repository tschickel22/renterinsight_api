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
end
