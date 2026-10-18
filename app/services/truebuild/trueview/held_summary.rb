# frozen_string_literal: true

module Truebuild
  module Trueview
    # What is still held back after a run has fixed what it can, grouped by
    # what the check found, so a person decides a handful of groups instead of
    # looking at hundreds of drawings. The check is stricter than a buyer:
    # after two factories (2026-10-17) most held drawings were a shade off the
    # sample or missed a sliver of trim, and buyers are told the pictures are
    # illustrations. A group can be shown as it is, from its score 3 up (a 2
    # is the wrong finish), except a drawing that changed nothing or drew the
    # wrong kind of refrigerator: those show the wrong thing however close.
    #
    # Sorted by the check's own note, by pattern: nothing is paid for.
    module HeldSummary
      module_function

      SHOW_FROM = 3   # scores a group's "show these" covers
      EXAMPLES = 6    # drawings shown for each group

      PART = /\b(while|but|only|other|rest of|remaining|leftmost|rightmost|left[- ]side|right[- ]side|one of)\b/i
      PIECE = /\b(left|right|upper|lower|top|bottom|panel|door|trim|post|leg|corner|strip|band|edge|filler|island|perimeter|pair|window|section|portion|piece|base|box|end wall|fascia|dishwasher|range|microwave|hood|refrigerator)\b/i
      LEFT_OLD = /unchanged|remain|retain|\bstill\b|left in|kept|not (fully )?(recolou?red|changed|replaced|updated|covered|painted)/i
      REASONS = [
        { key: 'fridge_style', label: 'A different kind of refrigerator', keep_hidden: true,
          advice: 'The color is usually right; the door layout is not (a top-freezer for a side-by-side, or the other way). Kept hidden: ' \
                  'a buyer choosing a top-freezer should not see a side-by-side.',
          match: ->(n, s, _v = nil) { s.to_s.match?(OptionLook::APPLIANCES) && n.match?(/top[- ]freezer|side[- ]by[- ]side|\bsxs\b|french door|single[- ]door|over\/under|bottom[- ]freezer|dispenser|configuration/i) } },
        { key: 'unchanged', label: 'Not changed at all', keep_hidden: true,
          advice: 'The drawing left the surface as it was in the photo. Kept hidden: showing it shows the wrong finish.',
          match: ->(n, _s, _v = nil) { n.match?(/unchanged|barely changed|virtually identical|nearly identical|identical to the|essentially the same|no change (to|is|has)|no (discernible|visible|noticeable|apparent) (change|difference)|has not been (changed|applied|recolou?red)|not been applied|negligible/i) && !n.match?(PART) } },
        # Held for a reviewer whenever a run ends: on the first two factories
        # Tom hid most of these (2026-10-18), and the check's note cannot tell
        # the bad ones from the rest. Everything else from score 3 up is shown
        # when a run ends (auto_show!).
        { key: 'appliance_changed', label: 'The appliance itself changed', review: true,
          advice: 'A gas range for an electric one, a microwave swapped for a hood, part of the hood erased. You hid 7 of 9 of these.',
          match: ->(n, _s, _v = nil) { n.match?(/\bgas\b|coil|grates|microwave.*(replaced|removed)|replaced.*microwave|range hood.*(lost|missing|erased)|no refrigerator/i) } },
        { key: 'bleed_through', label: 'Old finish showing at the edges', review: true,
          advice: 'A fringe of the old finish along cabinet edges or trim. You hid 5 of 6 of these.',
          match: ->(n, _s, _v = nil) { n.match?(/bleed|fringe|remnant|ghost/i) } },
        { key: 'more_than_one_wall', label: 'Accent color on more than one wall', review: true,
          advice: 'An accent wall color carried onto a second wall. You hid both of these.',
          match: ->(n, _s, _v = nil) { n.match?(/more than one wall|multiple walls|wraps around|entire back wall/i) } },
        { key: 'white_cream', label: 'White cabinets drawn creamy', review: true,
          advice: 'A white finish that reads cream or yellow. You showed about half of these, so each one is your call.',
          match: ->(n, s, v = nil) { s.to_s.match?(/cabinet|lav/i) && v.to_s.match?(/white/i) && n.match?(/cream|yellow|ivory/i) } },
        { key: 'spill', label: 'Color spilled onto something else',
          advice: 'The finish reached a nearby surface, or something else changed with it (hardware, trim, a neighbor).',
          match: ->(n, _s, _v = nil) { n.match?(/spill|\bbled\b|bleed|unintended|not part of|should (have )?remain|extends? (into|onto|beyond)|also (been )?(changed|recolou?red)|rather than being (limited|confined|contained|restricted)|hardware|\bpulls\b|knobs/i) } },
        { key: 'missed_part', label: 'Part of the surface left as it was',
          advice: 'Most of the surface changed; a piece (a door, a strip of trim, one shutter pair) kept the old finish.',
          match: ->(n, _s, _v = nil) { n.match?(LEFT_OLD) && (n.match?(PART) || n.match?(PIECE)) } },
        { key: 'blotchy', label: 'Uneven or patchy',
          advice: 'The new finish is there but splotchy or streaked.',
          match: ->(n, _s, _v = nil) { n.match?(/blotch|splotch|patch|uneven|streak|mottled|smear|halo/i) } },
        { key: 'texture', label: 'Pattern or texture off',
          advice: 'The color is close; the grain, veining, tile or style does not look like the sample.',
          match: ->(n, _s, _v = nil) { n.match?(/grain|textur|pattern|vein|marble|swirl|beadboard|shaker|\brail|stile|3-tab|dimensional/i) } },
        { key: 'shade', label: 'A shade off the sample',
          advice: 'The right finish, a little lighter, darker, warmer or cooler than the sample.',
          match: ->(n, _s, _v = nil) { n.match?(/lighter|darker|warmer|cooler|\bdark|\blight\b|\btan\b|white|brown|\btone|shade|\bhue|saturat|tint|cream|yellow|gr[ae]y|colou?r|#\h{6}/i) } },
        { key: 'other', label: 'Something else', advice: 'Look at the examples.', match: ->(*) { true } }
      ].freeze

      def reason(note, surface, value = nil)
        n = note.to_s.delete_prefix('Hidden: ')
        REASONS.find { |r| r[:match].call(n, surface, value) }[:key]
      end

      def group_of(r) = reason(note(r), surface(r), r.selection.first&.dig('value'))

      # A factory run's drawing that failed its check but will be shown when
      # the run ends anyway (auto_show!): drawing it again buys nothing. On
      # run 4 (2026-10-18) held drawings cost $0.30 each against $0.09 for one
      # that passed, almost all of it redraws of drawings shown in the end.
      def shown_anyway?(render, verdict)
        return false unless render.usage['factory_run_id'] && verdict && !verdict['ok'] && verdict['score'].to_i >= SHOW_FROM

        group = find(reason(verdict['note'], render.selection.first&.dig('surface'), render.selection.first&.dig('value')))
        !(group[:keep_hidden] || group[:review])
      end

      # When a run ends: every held drawing from score 3 up shown, but for
      # groups held for a reviewer (review) or never shown (keep_hidden).
      # They are listed as shown automatically, to look through and hide any.
      # => how many.
      def auto_show!(run)
        stamp = { 'auto' => true, 'at' => Time.current.iso8601 }
        shown = 0
        held(run).find_each do |r|
          next if score(r) < SHOW_FROM

          key = group_of(r)
          group = find(key)
          next if group[:keep_hidden] || group[:review]

          r.update!(status: 'done', error: nil, usage: r.usage.merge('approved' => stamp.merge('group' => key)))
          shown += 1
        end
        shown
      end

      # Shown automatically and not looked through yet.
      def auto_shown(run = nil)
        rows = (run ? run.renders : TruebuildRender.where(purpose: 'layer')).where(status: 'done')
                 .where("usage->'approved'->>'auto' = 'true'").where.not("usage->'approved' ? 'looked'")
                 .select(:id, :selection, :usage, :error, :source_url, :layer_url, :catalog_plan_variant_id).to_a
        names = names_for(rows)
        rows.sort_by(&:id).map { |r| example(r, names).merge(group: r.usage.dig('approved', 'group')) }
      end

      # The reviewer looked through what was shown automatically: hide_ids go
      # back to hidden for good, the rest stay shown and leave the list.
      # => { hidden:, kept: }
      def look_through!(ids, hide_ids:, by:)
        stamp = { 'by' => by&.id, 'at' => Time.current.iso8601 }
        hide = Array(hide_ids).map(&:to_i)
        out = { hidden: 0, kept: 0 }
        TruebuildRender.where(id: Array(ids).map(&:to_i) + hide, purpose: 'layer', status: 'done')
                       .where("usage->'approved'->>'auto' = 'true'").find_each do |r|
          if hide.include?(r.id)
            note = r.usage.dig('check', 'note').presence || 'hidden after it was shown automatically'
            r.update!(status: 'rejected', error: "Hidden: #{note}",
                      usage: r.usage.except('approved').merge('kept_hidden' => stamp.merge('group' => r.usage.dig('approved', 'group'), 'auto' => true)))
            out[:hidden] += 1
          else
            r.update!(usage: r.usage.merge('approved' => r.usage['approved'].merge('looked' => stamp)))
            out[:kept] += 1
          end
        end
        out
      end

      # Held back and not yet decided: a drawing a reviewer chose to keep
      # hidden is out of the groups for good.
      def held(run = nil)
        rows = run ? run.renders : TruebuildRender.where(purpose: 'layer')
        rows.where(status: 'rejected').where.not(catalog_plan_variant_id: nil).where.not(layer_url: nil)
            .where.not("usage ? 'kept_hidden'")
      end

      # => [{ key, label, advice, count, keep_hidden, showable, scores, examples, reviewed }],
      # largest first. reviewed: what a reviewer already decided in the group
      # ({ shown, kept_hidden }), so a group gone through says so, and stays
      # listed when nothing is left in it.
      def call(run = nil)
        groups = rows(run).group_by { |r| group_of(r) }
        names = names_for(groups.values.flatten)
        decided = reviewed(run)
        REASONS.filter_map do |r|
          list = groups[r[:key]] || []
          next if list.empty? && !decided.key?(r[:key])

          scores = list.map { |x| score(x) }.tally.transform_keys(&:to_s)
          { key: r[:key], label: r[:label], advice: r[:advice], count: list.size, keep_hidden: r[:keep_hidden] == true,
            review: r[:review] == true,
            showable: r[:keep_hidden] ? 0 : list.count { |x| score(x) >= SHOW_FROM }, scores: scores,
            examples: list.sort_by { |x| -score(x) }.first(EXAMPLES).map { |x| example(x, names) },
            reviewed: decided[r[:key]] || { shown: 0, kept_hidden: 0 } }
        end.sort_by { |g| -g[:count] }
      end

      # { group key => { shown:, kept_hidden: } } from the stamps show! leaves.
      def reviewed(run = nil)
        rows = run ? run.renders : TruebuildRender.where(purpose: 'layer')
        out = Hash.new { |h, k| h[k] = { shown: 0, kept_hidden: 0 } }
        rows.where("usage->'approved' ? 'group'").where.not("usage->'approved' ? 'auto'").group(Arel.sql("usage->'approved'->>'group'")).count
            .each { |k, n| out[k][:shown] += n }
        rows.where("usage->'kept_hidden' ? 'group'").where.not("usage->'kept_hidden' ? 'auto'").group(Arel.sql("usage->'kept_hidden'->>'group'")).count
            .each { |k, n| out[k][:kept_hidden] += n }
        out.to_h
      end

      # Every drawing in a group, best score first, each saying whether it
      # can be shown, to go through before showing the rest.
      def items(key, run = nil)
        group = find(key)
        list = rows(run).select { |r| group_of(r) == key }.sort_by { |r| [-score(r), r.id] }
        names = names_for(list)
        list.map { |r| example(r, names).merge(showable: !group[:keep_hidden] && score(r) >= SHOW_FROM) }
      end

      # Shows the group's drawings named in ids that score SHOW_FROM or better,
      # as a reviewer's approval would one at a time, and keeps the ones in
      # hide_ids hidden for good. ids nil: every one that can be shown.
      # => { shown:, kept_hidden: }
      def show!(key, by:, run: nil, ids: nil, hide_ids: [])
        group = find(key)
        raise ArgumentError, "#{group[:label]} stays hidden" if group[:keep_hidden]

        stamp = { 'by' => by&.id, 'at' => Time.current.iso8601, 'group' => key }
        ids = ids&.map(&:to_i)
        hide = Array(hide_ids).map(&:to_i)
        out = { shown: 0, kept_hidden: 0 }
        held(run).where(id: ids ? ids + hide : held(run).select(:id)).find_each do |r|
          next unless group_of(r) == key

          if hide.include?(r.id)
            r.update!(usage: r.usage.merge('kept_hidden' => stamp))
            out[:kept_hidden] += 1
          elsif score(r) >= SHOW_FROM
            r.update!(status: 'done', error: nil, usage: r.usage.merge('approved' => stamp))
            out[:shown] += 1
          end
        end
        out
      end

      def find(key)
        REASONS.find { |r| r[:key] == key } or raise ArgumentError, 'No such group'
      end

      def rows(run)
        held(run).select(:id, :selection, :usage, :error, :source_url, :layer_url, :catalog_plan_variant_id).to_a
      end

      def names_for(rows)
        CatalogPlanVariant.where(id: rows.map(&:catalog_plan_variant_id).uniq)
                          .pluck(:id, Arel.sql("media->>'name'"), :model_number).to_h { |i, n, m| [i, n.presence || m] }
      end

      # One line for the end-of-run notice: "12 a shade off, 8 part left as it was".
      def line(run)
        call(run).select { |g| g[:count].positive? }.first(4).map { |g| "#{g[:count]} #{g[:label].downcase}" }.join(', ')
      end

      def note(r) = r.usage.dig('check', 'note').presence || r.error.to_s
      def surface(r) = r.selection.first&.dig('surface')
      def score(r) = r.usage.dig('check', 'score').to_i

      def example(r, names)
        { id: r.id, model: names[r.catalog_plan_variant_id], surface: surface(r), value: r.selection.first&.dig('value'),
          score: score(r), note: note(r).delete_prefix('Hidden: '), photo_url: Trueview.sized(r.source_url), layer_url: r.layer_url }
      end
    end
  end
end
