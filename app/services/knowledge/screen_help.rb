# frozen_string_literal: true

# What can teach someone the screen they are on: the videos, tours and articles
# behind the Learn icon in the header (E91). Only the best matching screen counts,
# so /deals/projects shows Projects help and not everything about Deals.
#
# Videos are tied to screens by their "Screens it shows" list, and tours by the pages
# their steps visit. Articles only belong to a module, and a module's stored route is
# an API path, so MODULE_SCREENS says which screens each module's articles explain.
class Knowledge::ScreenHelp
  SETTINGS_PATH = '/settings'
  DEFAULT_SETTINGS_TAB = 'general'
  TAB_MARKER = /\Asettings-tab:(.+)\z/
  TOUR_TAB_MARKER = /data-tour="settings-tab:([^"]+)"/

  MODULE_SCREENS = {
    'accounting' => ['/accounting'],
    'accounts' => ['/accounts'],
    'agreements' => ['/agreements'],
    'brochures' => ['/brochures'],
    'calendar' => ['/calendar'],
    'commissions' => ['/commissions'],
    'contacts' => ['/contacts'],
    'contractors' => ['/contractors'],
    'deals' => ['/deals'],
    'inventory' => ['/inventory'],
    'invoices' => ['/finance/invoices'],
    'leads' => ['/crm'],
    'payments' => ['/finance/payments'],
    'projects' => ['/deals/projects', '/projects'],
    'quotes' => ['/quotes'],
    'reports' => ['/reports'],
    'service' => ['/service'],
    'users' => ['/account/settings'],
    'warranty' => ['/warranty', '/inventory/warranty'],
    'website_builder' => ['/company/settings/website'],
    'workflow_automation' => ['/workflow-automation']
  }.freeze

  def initialize(path:, tab: nil, admin: false)
    @path = path.to_s.split('?').first.to_s.chomp('/').presence || '/'
    @tab = tab.presence || DEFAULT_SETTINGS_TAB
    @admin = admin
  end

  def videos
    best(TrainingVideo.visible(admin: @admin).ordered.to_a) do |video|
      next if on_settings? && !tab_allows?(Array(video.covers['markers']).filter_map { |m| m.to_s[TAB_MARKER, 1] })

      Array(video.covers['routes'])
    end
  end

  def tours
    return [] if PlatformSetting.tours_paused? && !@admin

    scope = @admin ? Tour.active : Tour.active.approved
    best(scope.ordered.includes(:steps).to_a) do |tour|
      next if on_settings? && !tab_allows?(tour.steps.filter_map { |s| s.selector.to_s[TOUR_TAB_MARKER, 1] })

      tour.menu_paths
    end
  end

  def articles
    records = Knowledge::Article.published.where.not(article_type: 'release_note')
                                .includes(:knowledge_module).ordered.to_a
    best(records) { |article| MODULE_SCREENS[article.knowledge_module&.key] }
  end

  private

  def on_settings?
    @path == SETTINGS_PATH
  end

  # Help with no tab named belongs to the whole Settings page.
  def tab_allows?(tabs)
    tabs.empty? || tabs.include?(@tab)
  end

  def best(records)
    scored = records.filter_map do |record|
      score = Array(yield(record)).filter_map { |route| score_of(route) }.max
      [record, score] if score
    end
    top = scored.map(&:last).max
    scored.select { |_, score| score == top }.map(&:first)
  end

  # A route covers a path it starts. A fixed word beats a :param, and longer beats
  # shorter: /deals/projects beats /deals/:dealId, which beats /deals.
  def score_of(route)
    route_parts = route.to_s.split('?').first.to_s.split('/').reject(&:empty?)
    path_parts = @path.split('/').reject(&:empty?)
    return if route_parts.empty? || route_parts.length > path_parts.length

    route_parts.each_with_index.sum do |part, i|
      next 1 if part.start_with?(':')
      return nil unless part == path_parts[i]

      2
    end
  end
end
