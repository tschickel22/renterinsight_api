# frozen_string_literal: true

module Truebuild
  # Once a day, tells the platform admins what the feeds brought in: homes
  # the Champion feed and the factory site crawls added to dealer lots, and
  # models new to the catalog. Most of it needs nothing, so the notice leads
  # with what does: a priced model with no TrueView drawings (a factory run
  # to schedule), a model with no factory prices (it cannot be configured),
  # and a home no model matched (its buyers get no designer at all).
  module NewHomes
    module_function

    FEEDS = { 'champion_ims' => 'Champion feed', 'catalog_import' => 'factory sites',
              'catalog_inventory' => 'factory inventory' }.freeze
    MARK = 'new_homes_digest_at' # platform Setting: the end of the last digest's window
    LISTED = 5 # names per line in the notice

    def digest!(now: Time.current)
      since = last_digest_at || now - 1.day
      report = collect(since, now).merge(factories: FactoryReadiness.stage_changes!)
      notify!(report, since) if report[:homes].any? || report[:models].any? || report[:factories].any?
      Setting.set('platform', nil, MARK, now.iso8601(6))
      report
    end

    def last_digest_at
      Time.zone.parse(Setting.get('platform', nil, MARK).to_s)
    rescue ArgumentError
      nil
    end

    def collect(since, now)
      homes = Vehicle.where(source: FEEDS.keys, is_deleted: false, created_at: since...now)
                     .includes(:company, catalog_plan_variant: %i[catalog_plan manufacturer]).to_a
      models = CatalogPlanVariant.where(created_at: since...now).includes(:catalog_plan, :manufacturer).to_a
      variants = (models + homes.filter_map(&:catalog_plan_variant)).uniq
      priced = HomeMatcher.new.priced_ids
      drawn = ModelList.trueview_ready(variants.map(&:id))
      state = ->(v) { if !priced.include?(v.id) then 'no_price' elsif drawn.include?(v.id) then 'drawn' else 'needs_drawing' end }

      {
        homes: homes.map do |h|
          { id: h.id, source: h.source, company: h.company&.name, variant_id: h.catalog_plan_variant_id,
            name: [h.make, h.model].compact_blank.join(' ').squish }
        end,
        models: models.map { |v| { id: v.id, name: name(v), state: state.call(v) } },
        states: variants.to_h { |v| [v.id, { name: name(v), state: state.call(v) }] }
      }
    end

    def name(variant)
      plan = variant.catalog_plan
      [variant.manufacturer&.name, plan&.series, plan&.name, variant.model_number].compact_blank.uniq.join(' ')
    end

    def notify!(report, since)
      text = message(report, since)
      User.where(role: %w[platform_admin super_admin], deleted_at: nil).find_each do |user|
        NotificationService.create(
          recipient: user, notification_type: :new_homes_digest, title: title(report), message: text,
          action_url: '/settings?tab=integrations', action_text: 'Open TrueView', company_id: user.company_id,
          deliver_now: true, metadata: { 'since' => since.iso8601, 'report' => report.deep_stringify_keys }
        )
      rescue StandardError => e
        Rails.logger.warn("NewHomes digest to user #{user.id}: #{e.message}")
      end
    end

    def title(report)
      parts = []
      parts << "#{report[:homes].size} new #{'home'.pluralize(report[:homes].size)}" if report[:homes].any?
      parts << "#{report[:models].size} new #{'model'.pluralize(report[:models].size)}" if report[:models].any?
      return "#{parts.join(' and ')} from the feeds" if parts.any?

      "#{report[:factories].size} #{'factory'.pluralize(report[:factories].size)} changed stage"
    end

    def message(report, since)
      homes = report[:homes]
      states = report[:states]
      lines = []
      if homes.any?
        by_feed = homes.group_by { |h| h[:source] }.map do |source, hs|
          dealers = hs.group_by { |h| h[:company] }.map { |c, list| "#{c || 'no dealer'} #{list.size}" }
          "#{hs.size} from the #{FEEDS[source]} (#{dealers.first(LISTED).join(', ')})"
        end
        lines << "Since #{since.in_time_zone('America/Denver').strftime('%b %-d %-l:%M %p')}: #{by_feed.join('; ')}."
      end
      lines << "New in the catalog: #{listed(report[:models].map { |m| m[:name] })}." if report[:models].any?

      linked = (homes.filter_map { |h| h[:variant_id] } + report[:models].map { |m| m[:id] }).uniq
      needs = linked.select { |id| states.dig(id, :state) == 'needs_drawing' }.map { |id| states[id][:name] }
      unpriced = linked.select { |id| states.dig(id, :state) == 'no_price' }.map { |id| states[id][:name] }
      unmatched = homes.reject { |h| h[:variant_id] }.map { |h| h[:name].presence || "home #{h[:id]}" }.uniq
      lines << "Needs a factory run (priced, no drawings): #{listed(needs)}." if needs.any?
      lines << "No factory prices yet, so it cannot be configured: #{listed(unpriced)}." if unpriced.any?
      lines << "Not matched to any model: #{listed(unmatched)}." if unmatched.any?
      lines << 'Every new home matches a drawn model.' if homes.any? && needs.empty? && unpriced.empty? && unmatched.empty?
      if report[:factories].any?
        moves = report[:factories].map { |c| "#{c[:name]} #{FactoryReadiness::LABELS[c[:from]] || 'new'} to #{FactoryReadiness::LABELS[c[:to]]}" }
        lines << "Factories: #{listed(moves)}."
      end
      lines.join(' ')
    end

    def listed(names)
      more = names.size - LISTED
      names.first(LISTED).join(', ') + (more.positive? ? " and #{more} more" : '')
    end
  end
end
