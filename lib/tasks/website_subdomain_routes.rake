# frozen_string_literal: true

# Backfill Worker routes for sites that already have a platform subdomain.
#
# The route is created at subdomain assignment from now on, but every site that
# existed before that answered 403 on its subdomain because no route was ever
# bound. This walks them once.
#
# Safe to re-run: CloudflareSaasService#create_worker_route treats an existing
# route as success rather than a conflict.
#
#   bin/rails websites:backfill_subdomain_routes          # dry run
#   bin/rails websites:backfill_subdomain_routes APPLY=1  # actually write
namespace :websites do
  desc 'Bind the host-rewriting Worker to every existing site subdomain (APPLY=1 to write)'
  task backfill_subdomain_routes: :environment do
    apply = ENV['APPLY'].present?

    unless CloudflareSaasService.configured?
      warn 'Cloudflare is not configured in this environment. Nothing to do.'
      next
    end

    sites = Website.active.where.not(subdomain: [nil, '']).order(:id)
    root = Brand.current.site_host_root

    suffix = Websites::SiteAddress.label_suffix
    puts "site host root: #{root}"
    puts "environment label suffix: #{suffix.presence || '(none, production shape)'}"
    puts "sites with a subdomain: #{sites.count}"
    puts(apply ? 'MODE: applying' : 'MODE: dry run (pass APPLY=1 to write)')
    puts

    ok = failed = 0

    sites.find_each do |site|
      host = Websites::SubdomainRouteProvisioner.host_for(site)
      if host.blank?
        puts format('  skip   %-6s %s (no host could be built)', site.id, site.name)
        next
      end

      unless apply
        puts format('  would  %-6s %s', site.id, host)
        next
      end

      if Websites::SubdomainRouteProvisioner.ensure(site)
        ok += 1
        puts format('  bound  %-6s %s', site.id, host)
      else
        failed += 1
        puts format('  FAILED %-6s %s', site.id, host)
      end
    end

    next unless apply

    puts
    puts "bound: #{ok}   failed: #{failed}"
    puts 'Re-run to retry failures; already-bound routes are treated as success.' if failed.positive?
  end
end
