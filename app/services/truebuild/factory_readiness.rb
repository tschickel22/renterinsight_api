# frozen_string_literal: true

module Truebuild
  # One row per factory for the readiness board (backlog E64): its price
  # book, how many of its models are drawn, what the checks held back, what
  # the pattern pass left for a person, and where that puts it.
  #
  # Stages, worst first on the board:
  #   needs_review  drawings held back or a pattern needs a look
  #   ready         a published book, READY_SHARE of photographed models
  #                 drawn, nothing held back: waiting for a person to release it
  #   drawing       a run is going, or some models drawn but under the bar
  #   priced        a published book, nothing drawn yet
  #   not_started   no published book
  #   released      a platform admin released it; dealers can be given it
  #
  # Counts for every factory come from a handful of queries, cached briefly,
  # so the board stays quick at a hundred factories.
  module FactoryReadiness
    module_function

    SETTING = 'truebuild_ready_share'
    DEFAULT_SHARE = 0.9
    CACHE_KEY = 'truebuild:factory_readiness:v1'
    STAGE_ORDER = %w[needs_review ready drawing priced not_started released].freeze

    LABELS = { 'needs_review' => 'Needs review', 'ready' => 'Ready', 'drawing' => 'Drawing', 'priced' => 'Priced',
               'not_started' => 'Not started', 'released' => 'Released' }.freeze
    STAGES_SEEN = 'truebuild_factory_stages' # platform Setting: each factory's stage at the last daily notice

    # Factories whose stage moved since the last call, for the daily notice.
    # The first call only records where everything stands. Factories still
    # Not started are left out: there are many and nothing is happening.
    # => [{ name:, from:, to: }]
    def stage_changes!
      rows = build
      seen = Setting.get('platform', nil, STAGES_SEEN)
      Setting.set('platform', nil, STAGES_SEEN, rows.to_h { |r| [r[:id].to_s, r[:stage]] })
      return [] unless seen.is_a?(Hash)

      rows.filter_map do |r|
        from = seen[r[:id].to_s]
        next if from == r[:stage] || (from.nil? && r[:stage] == 'not_started')

        { name: [r[:manufacturer][:name], r[:name]].compact.uniq.join(' '), from: from, to: r[:stage] }
      end
    end

    def ready_share
      v = Setting.get('platform', nil, SETTING).to_f
      v.positive? && v <= 1 ? v : DEFAULT_SHARE
    end

    def board(refresh: false)
      Rails.cache.delete(CACHE_KEY) if refresh
      rows = Rails.cache.fetch(CACHE_KEY, expires_in: 10.minutes) { build }
      { rows: rows, ready_share: ready_share, spent_this_month: spent_this_month,
        totals: STAGE_ORDER.index_with { |s| rows.count { |r| r[:stage] == s } } }
    end

    def bust! = Rails.cache.delete(CACHE_KEY)

    def row(factory_id) = build(Factory.where(id: factory_id)).first

    def build(factories = Factory.active)
      factories = factories.includes(:manufacturer, :truebuild_released_by).to_a
      ids = factories.map(&:id)
      priced = CatalogVariantPrice.where(catalog_price_book_id: CatalogPriceBook.published.select(:id)).select(:catalog_plan_variant_id)
      variants = CatalogPlanVariant.active.joins(:catalog_plan).where(id: priced, catalog_plans: { factory_id: ids })
                                   .select('catalog_plan_variants.*', 'catalog_plans.factory_id AS plan_factory_id').to_a
      by_factory = variants.group_by(&:plan_factory_id)
      photographed = variants.select { |v| Trueview::PhotoChoice.photos(v).any? }.map(&:id).to_set
      drawn = ModelList.trueview_ready(photographed.to_a)
      held = held_back_by_variant(variants.map(&:id))
      books = latest_books(ids).merge(pricing_books(by_factory))
      runs = runs_by_factory(by_factory)
      dealers = DealerFactory.where(factory_id: ids).group(:factory_id).count
      share = ready_share

      factories.map do |f|
        vs = by_factory[f.id] || []
        with_photos = vs.count { |v| photographed.include?(v.id) }
        drawn_count = vs.count { |v| drawn.include?(v.id) }
        held_count = vs.sum { |v| held[v.id].to_i }
        run = runs[f.id]
        patterns = open_patterns(run)
        stats = { models: vs.size, with_photos: with_photos, drawn: drawn_count,
                  share: with_photos.zero? ? 0.0 : (drawn_count.to_f / with_photos).round(3),
                  held_back: held_count, patterns: patterns }
        { id: f.id, name: f.name, code: f.code, city: f.city, state: f.state,
          manufacturer: { id: f.manufacturer_id, name: f.manufacturer&.name },
          book: books[f.id], **stats,
          run: run && { id: run.id, status: run.status, created_at: run.created_at, spent_usd: run.spent_usd.round(2) },
          stage: stage(f, books[f.id], stats, run, share),
          released: f.truebuild_released? ? { at: f.truebuild_released_at, by: f.truebuild_released_by&.full_name,
                                                note: f.truebuild_release_note, below_bar: stats[:share] < share } : nil,
          dealers: dealers[f.id].to_i }
      end.sort_by { |r| [STAGE_ORDER.index(r[:stage]), -r[:held_back], r[:manufacturer][:name].to_s, r[:name]] }
    end

    def stage(factory, book, stats, run, share)
      return 'released' if factory.truebuild_released?
      return 'not_started' unless book && book[:status] == 'published'
      return 'drawing' if run && %w[scheduled running].include?(run.status)
      return 'needs_review' if stats[:held_back].positive? || stats[:patterns].any?
      return 'ready' if stats[:with_photos].positive? && stats[:share] >= share
      return 'priced' if stats[:drawn].zero?

      'drawing'
    end

    # Held back by their check under the current cut, as the lab's Needs
    # attention list counts them (approving one makes it done).
    def held_back_by_variant(variant_ids)
      return {} if variant_ids.empty?

      TruebuildRender.where(purpose: 'layer', model_key: Trueview::Buyer::MODEL, status: 'rejected', catalog_plan_variant_id: variant_ids)
                     .where("(usage->>'mask_version')::int >= ?", Trueview::Layer::VERSION)
                     .group(:catalog_plan_variant_id).count
    end

    # The newest published book that prices each factory's models. One
    # package can cover two plants (BookResolver), so this goes by the price
    # rows, not the book's own plant: on staging Topeka's book prices the
    # Decatur models, and Decatur has no book of its own.
    def pricing_books(by_factory)
      ids = by_factory.values.flatten.map(&:id)
      return {} if ids.empty?

      pairs = CatalogVariantPrice.joins(:price_book).merge(CatalogPriceBook.published)
                                 .where(catalog_plan_variant_id: ids).distinct.pluck(:catalog_plan_variant_id, :catalog_price_book_id)
      books = CatalogPriceBook.where(id: pairs.map(&:last).uniq).index_by(&:id)
      book_ids = pairs.group_by(&:first).transform_values { |ps| ps.map(&:last) }
      by_factory.filter_map do |factory_id, vs|
        b = vs.flat_map { |v| book_ids[v.id] || [] }.uniq.map { |id| books[id] }.compact.max_by { |x| [x.published_at || x.created_at, x.id] }
        [factory_id, book_json(b)] if b
      end.to_h
    end

    # Each factory's own newest price book, for one not yet published or a
    # factory with no priced models: the published one if there is one.
    def latest_books(factory_ids)
      CatalogPriceBook.where(factory_id: factory_ids).order(:created_at).to_a.group_by(&:factory_id).transform_values do |bs|
        book_json(bs.select { |x| x.status == 'published' }.max_by { |x| x.published_at || x.created_at } || bs.last)
      end
    end

    def book_json(b) = { id: b.id, name: b.name, status: b.status, effective_on: b.effective_on, published_at: b.published_at }

    # Each factory's newest factory run: one for that factory, or one for its
    # manufacturer that drew some of its models.
    def runs_by_factory(by_factory)
      runs = TruebuildFactoryRun.where(manufacturer_id: by_factory.values.flatten.map(&:manufacturer_id).uniq)
                                .order(created_at: :desc).limit(200).to_a
      by_factory.transform_values do |vs|
        ids = vs.map(&:id).to_set
        factory_id = vs.first.plan_factory_id
        runs.find { |r| r.factory_id == factory_id || (r.factory_id.nil? && Array(r.variant_ids).any? { |id| ids.include?(id.to_i) }) }
      end
    end

    # What the pattern pass could not fix by outlining again (Patterns).
    def open_patterns(run)
      return [] unless run

      Array(run.progress['patterns']).reject { |p| p['cause'] == 'outline' }.map { |p| p.slice('surface', 'cause', 'summary') }
    end

    def spent_this_month
      TruebuildFactoryRun.where(created_at: Time.current.beginning_of_month..).sum(&:spent_usd).round(2)
    end
  end
end
