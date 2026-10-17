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
          match: ->(n, s) { s.to_s.match?(OptionLook::APPLIANCES) && n.match?(/top[- ]freezer|side[- ]by[- ]side|\bsxs\b|french door|single[- ]door|over\/under|bottom[- ]freezer|dispenser|configuration/i) } },
        { key: 'unchanged', label: 'Not changed at all', keep_hidden: true,
          advice: 'The drawing left the surface as it was in the photo. Kept hidden: showing it shows the wrong finish.',
          match: ->(n, _) { n.match?(/unchanged|barely changed|virtually identical|nearly identical|identical to the|essentially the same|no change (to|is|has)|no (discernible|visible|noticeable|apparent) (change|difference)|has not been (changed|applied|recolou?red)|not been applied|negligible/i) && !n.match?(PART) } },
        { key: 'spill', label: 'Color spilled onto something else',
          advice: 'The finish reached a nearby surface, or something else changed with it (hardware, trim, a neighbor).',
          match: ->(n, _) { n.match?(/spill|\bbled\b|bleed|unintended|not part of|should (have )?remain|extends? (into|onto|beyond)|also (been )?(changed|recolou?red)|rather than being (limited|confined|contained|restricted)|hardware|\bpulls\b|knobs/i) } },
        { key: 'missed_part', label: 'Part of the surface left as it was',
          advice: 'Most of the surface changed; a piece (a door, a strip of trim, one shutter pair) kept the old finish.',
          match: ->(n, _) { n.match?(LEFT_OLD) && (n.match?(PART) || n.match?(PIECE)) } },
        { key: 'blotchy', label: 'Uneven or patchy',
          advice: 'The new finish is there but splotchy or streaked.',
          match: ->(n, _) { n.match?(/blotch|splotch|patch|uneven|streak|mottled|smear|halo/i) } },
        { key: 'texture', label: 'Pattern or texture off',
          advice: 'The color is close; the grain, veining, tile or style does not look like the sample.',
          match: ->(n, _) { n.match?(/grain|textur|pattern|vein|marble|swirl|beadboard|shaker|\brail|stile|3-tab|dimensional/i) } },
        { key: 'shade', label: 'A shade off the sample',
          advice: 'The right finish, a little lighter, darker, warmer or cooler than the sample.',
          match: ->(n, _) { n.match?(/lighter|darker|warmer|cooler|\bdark|\blight\b|\btan\b|white|brown|\btone|shade|\bhue|saturat|tint|cream|yellow|gr[ae]y|colou?r|#\h{6}/i) } },
        { key: 'other', label: 'Something else', advice: 'Look at the examples.', match: ->(_, _) { true } }
      ].freeze

      def reason(note, surface)
        n = note.to_s.delete_prefix('Hidden: ')
        REASONS.find { |r| r[:match].call(n, surface) }[:key]
      end

      # Held back and not yet decided: a drawing a reviewer chose to keep
      # hidden is out of the groups for good.
      def held(run = nil)
        rows = run ? run.renders : TruebuildRender.where(purpose: 'layer')
        rows.where(status: 'rejected').where.not(catalog_plan_variant_id: nil).where.not(layer_url: nil)
            .where.not("usage ? 'kept_hidden'")
      end

      # => [{ key, label, advice, count, keep_hidden, showable, scores, examples }], largest first.
      def call(run = nil)
        groups = rows(run).group_by { |r| reason(note(r), surface(r)) }
        names = names_for(groups.values.flatten)
        REASONS.filter_map do |r|
          list = groups[r[:key]] or next
          scores = list.map { |x| score(x) }.tally.transform_keys(&:to_s)
          { key: r[:key], label: r[:label], advice: r[:advice], count: list.size, keep_hidden: r[:keep_hidden] == true,
            showable: r[:keep_hidden] ? 0 : list.count { |x| score(x) >= SHOW_FROM }, scores: scores,
            examples: list.sort_by { |x| -score(x) }.first(EXAMPLES).map { |x| example(x, names) } }
        end.sort_by { |g| -g[:count] }
      end

      # Every drawing in a group, best score first, each saying whether it
      # can be shown, to go through before showing the rest.
      def items(key, run = nil)
        group = find(key)
        list = rows(run).select { |r| reason(note(r), surface(r)) == key }.sort_by { |r| [-score(r), r.id] }
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
          next unless reason(note(r), surface(r)) == key

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
        call(run).first(4).map { |g| "#{g[:count]} #{g[:label].downcase}" }.join(', ')
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
