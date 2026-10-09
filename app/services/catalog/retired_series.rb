# frozen_string_literal: true

module Catalog
  # A series a plant no longer builds or a dealer no longer sells (Champion
  # Genesis at Topeka): its models are discontinued, so they leave the Deal
  # Sheet's model picker, the buyer's model lists and auto-linking. A
  # platform setting remembers it, because publishing a book makes every model
  # it prices active again; the publisher applies the list after each publish.
  # Restoring the series makes its models active again.
  module RetiredSeries
    module_function

    KEY = 'retired_series' # { "<factory id>" => ["Champion Genesis", ...] }

    def all = Setting.get('platform', nil, KEY, {}).to_h

    def for(factory) = Array(all[factory.id.to_s])

    def retired?(factory, series) = self.for(factory).any? { |s| s.casecmp?(series.to_s) }

    def retire!(factory, series)
      list = (self.for(factory) | [series.to_s]).sort
      Setting.set('platform', nil, KEY, all.merge(factory.id.to_s => list))
      variants(factory, series).update_all(status: 'discontinued', updated_at: Time.current)
    end

    def restore!(factory, series)
      list = self.for(factory).reject { |s| s.casecmp?(series.to_s) }
      Setting.set('platform', nil, KEY, all.merge(factory.id.to_s => list))
      variants(factory, series).update_all(status: 'active', updated_at: Time.current)
    end

    # After a publish: a retired series stays retired.
    def apply!(factory)
      return 0 unless factory

      self.for(factory).sum { |series| variants(factory, series).where(status: 'active').update_all(status: 'discontinued', updated_at: Time.current) }
    end

    def variants(factory, series)
      CatalogPlanVariant.joins(:catalog_plan).where(catalog_plans: { factory_id: factory.id })
                        .where('LOWER(catalog_plans.series) = ?', series.to_s.downcase)
    end
  end
end
