# frozen_string_literal: true

# The Learning Center map (/learn): the path from a first inquiry to money in the
# bank, as stages, each with the videos, tours and articles that teach it.
#
# Nothing here is placed by hand. A video lands on a stage by the screens it
# shows (its "Screens it shows" list), a tour by the pages its steps visit, and
# an article by the screens its module explains (ScreenHelp::MODULE_SCREENS). So
# a new video joins the map by being tied to its screens, the same step that
# already keeps it in the "help follows the feature" check. Anything that
# matches no stage goes under More rather than disappearing.
class Knowledge::LearnMap
  # In the order a home moves through the business. A screen goes to the stage
  # with the most specific match, so /deals/projects is Build and install, not Deals.
  STAGES = [
    # Workflow videos walk the whole path, so they open the map rather than sit on one stage.
    { key: 'start', title: 'Start here', blurb: 'The whole path, start to finish.', screens: [] },
    { key: 'leads', title: 'Leads', blurb: 'Catch every inquiry and follow up.',
      screens: %w[/crm /inbox /workqueue /calendar /tasks] },
    { key: 'customers', title: 'Customers', blurb: 'The people and households you sell to.',
      screens: %w[/accounts /contacts] },
    { key: 'deal', title: 'Quote and deal', blurb: 'Put a home in front of a buyer and write it up.',
      screens: %w[/quotes /deals /deal-desk /agreements] },
    { key: 'home', title: 'Price and build the home', blurb: 'The Deal Sheet, options and the factory order.',
      screens: %w[/deals/:id?tab=home_build /deals/:dealId?tab=home_build /inventory] },
    # TrueBuild is its own product with its own course: every TrueBuild video sits
    # here (by area, like workflows), whatever screen it shows.
    { key: 'truebuild', title: 'TrueBuild', blurb: 'Your price book, the buyer designer and the Deal Sheet.',
      screens: %w[/truebuild] },
    { key: 'close', title: 'Close and approve', blurb: 'Accounting checks the deal before it posts.',
      screens: %w[/accounting/deals-commissions /commissions] },
    # A project's page is /deals/:dealId (a deal's is /deals/:id), so the name tells them apart.
    { key: 'build', title: 'Build and install', blurb: 'Projects, bids and the crews who do the work.',
      screens: %w[/deals/projects /deals/:dealId /projects /contractor /linked-companies /contractors] },
    { key: 'money', title: 'Get paid and keep the books', blurb: 'Invoices, payments, bills and reports.',
      screens: %w[/accounting /finance /reports] },
    { key: 'setup', title: 'Set up your company', blurb: 'Settings, users, locations and imports.',
      screens: %w[/settings /locations /account/settings /data /company /dashboard /service /warranty] }
  ].freeze
  MORE = { key: 'more', title: 'More', blurb: 'Everything else.', screens: [] }.freeze
  # Areas whose videos sit on one stage whatever screens they show.
  AREA_STAGES = { 'workflows' => 'start', 'truebuild' => 'truebuild' }.freeze

  def initialize(admin: false)
    @admin = admin
  end

  # [{ key:, title:, blurb:, videos: [TrainingVideo], tours: [Tour], articles: [Article] }]
  def stages
    @stages ||= begin
      out = (STAGES + [MORE]).to_h { |s| [s[:key], s.merge(videos: [], tours: [], articles: [])] }
      videos.each do |v|
        key = AREA_STAGES[v.module_key] || stage_for(Array(v.covers['routes']))
        out[key][:videos] << v
      end
      tours.each { |t| out[stage_for(t.menu_paths)][:tours] << t }
      articles.each { |a| out[stage_for(Knowledge::ScreenHelp::MODULE_SCREENS[a.knowledge_module&.key])][:articles] << a }
      out.values.reject { |s| (s[:videos] + s[:tours] + s[:articles]).empty? && %w[start truebuild more].include?(s[:key]) }
    end
  end

  # The stage whose screen matches one of these routes most specifically.
  def self.stage_key(routes)
    best = nil
    Array(routes).each do |route|
      STAGES.each do |stage|
        stage[:screens].each do |screen|
          score = score(screen, route)
          best = [score, stage[:key]] if score && (best.nil? || score > best[0])
        end
      end
    end
    best&.last || MORE[:key]
  end

  # A stage screen claims a route that starts with it, word for word; a :param
  # matches only the same :param (:dealId, a project, is not :id, a deal).
  # A query on the screen (?tab=home_build) must be on the route too, which
  # makes it the more specific match. Ties go to the route listed first.
  def self.score(screen, route)
    s_path, s_query = screen.split('?', 2)
    r_path, r_query = route.to_s.split('?', 2)
    s_parts = s_path.split('/').reject(&:empty?)
    r_parts = r_path.to_s.split('/').reject(&:empty?)
    return if s_parts.empty? || s_parts.length > r_parts.length
    return if s_query && !r_query.to_s.split('&').include?(s_query)

    s_parts.each_with_index.sum do |part, i|
      # Screens lists hold patterns, so a :param only matches the same :param
      # (/deals/new is not a project page).
      next 2 if part == r_parts[i]

      return nil
    end + (s_query ? 1 : 0)
  end

  private

  def stage_for(routes) = self.class.stage_key(routes)

  def videos
    TrainingVideo.visible(admin: @admin).ordered.to_a
  end

  # Same rules as the Learn icon: approved tours, none while tours are paused.
  def tours
    return [] if PlatformSetting.tours_paused? && !@admin

    (@admin ? Tour.active : Tour.active.approved).ordered.includes(:steps).to_a
  end

  def articles
    Knowledge::Article.published.standalone.includes(:knowledge_module).ordered.to_a
  end
end
