# frozen_string_literal: true

# Ask Google what it did with a dealer's site.
#
# Read-only and stores nothing. Everything else in this area is our own opinion
# about markup; this is the only thing that reports what Google actually saw, so
# the first useful form of it is a person running it and reading the answer.
# Persistence and a dashboard are worth building once there are enough live
# dealer sites to warrant one. Today there is one.
#
#   bin/rails "search_console:inspect[https://www.tomshotsauce.com/]"
#
# Requires the property to be verified in Search Console and
# SEARCH_CONSOLE_REFRESH_TOKEN to be set. See Seo::SearchConsole for the setup.
namespace :search_console do
  desc 'Report what Google indexed for a site, sampling its home pages'
  task :inspect, [:site_url] => :environment do |_t, args|
    site_url = args[:site_url].presence
    abort 'Usage: bin/rails "search_console:inspect[https://dealer.com/]"' if site_url.blank?

    host = URI.parse(site_url).host
    website = Websites::HostResolver.new(host).call if defined?(Websites::HostResolver)
    urls = [site_url]

    # The listings are what a dealer cares about, and they are also the pages
    # most likely to be discovered but not indexed.
    if website.respond_to?(:company) && website&.company
      urls += website.company.vehicles
                     .where(is_deleted: [false, nil], status: Websites::HomeUrl::SERVABLE_STATUSES)
                     .order(updated_at: :desc).limit(5)
                     .filter_map { |v| Websites::HomeUrl.url_for(v, host) }
    end

    puts "Asking Google about #{urls.size} #{'page'.pluralize(urls.size)} on #{site_url}"
    puts

    Seo::SearchConsole.inspect_urls(site_url: site_url, page_urls: urls).each do |result|
      unless result.ok?
        puts "  ERROR  #{result.url}  #{result.error}"
        next
      end

      state = result.indexed? ? 'INDEXED' : 'NOT INDEXED'
      puts "  #{state.ljust(11)} #{result.url}"
      puts "              #{result.coverage_state}" if result.coverage_state.present?
      puts "              last crawled #{result.last_crawled_at}" if result.last_crawled_at.present?
      puts "              rich results: #{result.rich_results.join(', ')}" if result.rich_results.present?
      result.rich_result_issues.each { |issue| puts "              BLOCKED: #{issue}" }
    end
  end
end
