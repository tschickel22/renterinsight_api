# frozen_string_literal: true

# Are the menu's permission gates telling the truth about what its pages need?
#
# The sidebar hides an item unless you hold one resource. A page, though, calls
# many endpoints, and each one gates on whatever its own controller says. When
# those disagree the menu lies in one of two directions:
#
#   OVER-EXPOSED  the item shows, then the page 403s on something else
#                 (Review Updates gated on 'deals' while contractor_reviews
#                  gates on 'projects' — the bug that prompted this task)
#   UNREACHABLE   the item is hidden from someone whose pages would have worked
#
# Static analysis, so treat it as a list of things to look at rather than a
# verdict: it maps a route's frontend module to the API paths that appear in it,
# resolves those to controllers, and collects the keys they enforce.
#
#   bin/rails rbac:wiring_audit
#   FRONTEND=/path/to/frontend bin/rails rbac:wiring_audit
namespace :rbac do
  DEFAULT_FRONTEND = '/Users/toms./src/Platform_DMS_8.4.25'

  desc 'Compare each nav item\'s permission gate against what its pages enforce'
  task wiring_audit: :environment do
    frontend = ENV.fetch('FRONTEND', DEFAULT_FRONTEND)
    nav_file = File.join(frontend, 'src/config/navigation.tsx')

    unless File.exist?(nav_file)
      abort "Cannot find #{nav_file}. Pass FRONTEND=/path/to/frontend."
    end

    nav = parse_nav(File.read(nav_file))
    routes = api_routes
    enforced = controller_keys

    puts "Auditing #{nav.size} nav items with a resource gate\n\n"

    findings = nav.filter_map do |item|
      dir = module_dir_for(frontend, item[:href])
      next unless dir

      needed = resources_used_in(dir, routes, enforced)
      extra = needed - [item[:resource]].compact
      next if extra.empty?

      { item: item, dir: dir.sub("#{frontend}/", ''), extra: extra.sort }
    end

    if findings.empty?
      puts 'No mismatches found.'
    else
      findings.each do |f|
        puts "#{f[:item][:name]}  (#{f[:item][:href]})"
        puts "  menu gates on : #{f[:item][:resource]}"
        puts "  pages also need: #{f[:extra].join(', ')}"
        puts "  scanned        : #{f[:dir]}"
        puts
      end
      puts "#{findings.size} nav item(s) whose pages need more than the menu asks for."
    end
  end

  # --- helpers -------------------------------------------------------------

  def self.parse_nav(source)
    source.scan(/name: '([^']+)'[^}]*?href: '([^']+)'[^}]*?resource: '([a-z_]+)'/).map do |name, href, resource|
      { name: name, href: href, resource: resource }
    end
  end

  # path template => controller, for every API route.
  def self.api_routes
    Rails.application.routes.routes.filter_map do |route|
      spec = route.path.spec.to_s.sub('(.:format)', '')
      next unless spec.start_with?('/api/')

      [spec, route.defaults[:controller]]
    end.to_h
  end

  # controller => set of resource keys it enforces.
  def self.controller_keys
    Dir[Rails.root.join('app/controllers/**/*.rb')].each_with_object({}) do |path, acc|
      keys = File.read(path).scan(/authorize_action!\(\s*'([a-z_]+)'/).flatten.uniq
      next if keys.empty?

      controller = path.sub("#{Rails.root}/app/controllers/", '').sub('.rb', '').sub('_controller', '')
      acc[controller] = keys
    end
  end

  # Best-effort: find the frontend directory that serves a nav href.
  def self.module_dir_for(frontend, href)
    slug = href.split('/').reject(&:empty?).first
    return nil unless slug

    candidates = Dir[File.join(frontend, 'src/modules/*')].select do |d|
      base = File.basename(d)
      base.include?(slug) || slug.include?(base.split('-').first.to_s)
    end
    candidates.first
  end

  def self.resources_used_in(dir, routes, enforced)
    paths = Dir[File.join(dir, '**/*.{ts,tsx}')].flat_map do |f|
      File.read(f).scan(%r{/api/v1/[a-zA-Z0-9/_-]+}).map { |p| p.chomp('/') }
    end.uniq

    paths.filter_map { |p| enforced[routes[normalise(p, routes)]] }.flatten.uniq
  rescue StandardError
    []
  end

  # Match a literal path against a route template, tolerating :id segments.
  def self.normalise(path, routes)
    return path if routes.key?(path)

    routes.keys.find do |template|
      regex = Regexp.new("\\A#{template.gsub(/:[a-z_]+/, '[^/]+')}\\z")
      path.match?(regex)
    end || path
  end
end
