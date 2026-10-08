# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Claude reads a published book's buyer-facing options for what their
    # names do not say, and what it decides applies in the designer at once
    # (CatalogOptionDecision). The name rules in code (Truebuild::OptionFamilies,
    # the tile and floor color rules) catch the wordings seen so far; a book
    # worded another way slipped past them, and a buyer saw three fridges or
    # ten tiles for five until someone noticed.
    #
    # It learns two ways. Options keep their key from one book to the next,
    # so a decision carries to next year's book without being asked again.
    # And the manufacturer's latest accepted and rejected decisions go into
    # the prompt as examples, so Claude follows each factory's way of naming.
    #
    # Only options a buyer chooses among are sent (kitchen, floors, tile,
    # cabinets, counters, exterior colors, fireplaces, standard items that may
    # be colors), and only ones with no decision yet, so a second run of the
    # same book costs nothing.
    class OptionReview
      BATCH = 150
      EXAMPLES = 40
      BUYER_GROUPS = /kitchen|appliance|floor|backsplash|tile|cabinet|counter|exterior|roof|fireplace|interior|bath|package/i

      TOOL = {
        name: 'record_option_decisions',
        description: 'Record what the option names imply for a buyer choosing finishes and upgrades for one home.',
        input_schema: {
          type: 'object',
          properties: {
            families: {
              type: 'array',
              description: 'Sets of options a home has exactly one of, where picking one must clear the others: every ' \
                           'refrigerator upgrade, every appliance package, every fireplace. Not options a home can have ' \
                           'several of (per room, per window, each).',
              items: { type: 'object', required: %w[family ids reason],
                       properties: { family: { type: 'string', description: 'short lowercase name, e.g. "refrigerator"' },
                                     ids: { type: 'array', items: { type: 'integer' } },
                                     reason: { type: 'string' } } }
            },
            not_families: {
              type: 'array',
              description: 'Options currently in a family (shown as family=...) that are wrongly there: a buyer can have ' \
                           'them alongside the others.',
              items: { type: 'object', required: %w[ids reason],
                       properties: { ids: { type: 'array', items: { type: 'integer' } }, reason: { type: 'string' } } }
            },
            same_finish: {
              type: 'array',
              description: 'Color chips in one set that are the same finish spelled two ways ("1 Row Ceramic Inhale Gris" ' \
                           'and "1 Row Inhale Gris (ceramic)"). Never different colors, sizes or row counts.',
              items: { type: 'object', required: %w[ids show reason],
                       properties: { ids: { type: 'array', items: { type: 'integer' } },
                                     show: { type: 'string', description: 'the clearest spelling, usually one of theirs' },
                                     reason: { type: 'string' } } }
            },
            color_choices: {
              type: 'array',
              description: 'Standard (included) items that are really a color the buyer picks one of, like sheet vinyl ' \
                           'floor colors listed as "Thunder (9661)". Not features.',
              items: { type: 'object', required: %w[ids set reason],
                       properties: { ids: { type: 'array', items: { type: 'integer' } },
                                     set: { type: 'string', description: 'the choice, e.g. "Flooring", "Backsplash"' },
                                     reason: { type: 'string' } } }
            },
            includes: {
              type: 'array',
              description: 'Packages that already contain something also sold on its own, so a buyer must not get both: ' \
                           'an appliance package with a French door refrigerator includes the "refrigerator" family.',
              items: { type: 'object', required: %w[ids family reason],
                       properties: { ids: { type: 'array', items: { type: 'integer' } },
                                     family: { type: 'string', description: 'the family it includes' },
                                     reason: { type: 'string' } } }
            }
          }
        }
      }.freeze

      SYSTEM = 'You organize a manufactured home factory price book for a buyer designing their home online. Decide ' \
               'only what the option names make clear; leave anything uncertain out. Options are given as ' \
               'id | group | name | flags.'

      def initialize(book)
        @book = book
        @mfr = book.manufacturer_id
      end

      # => { suggestions:, options_sent:, cost_usd: }
      def call
        options = candidates
        cost = 0.0
        made = 0
        options.each_slice(BATCH) do |batch|
          result = ClaudeClient.call(system: SYSTEM, tool: TOOL, max_tokens: 8000, temperature: 0,
                                     content: [{ type: 'text', text: prompt(batch) }])
          cost += ClaudeClient.cost_usd(result[:input_tokens], result[:output_tokens])
          made += record(result[:input], batch.to_h { |o| [o.id, o] })
        end
        summary = { 'suggestions' => made, 'options_sent' => options.size, 'cost_usd' => cost.round(4), 'ran_at' => Time.current.iso8601 }
        @book.update!(metadata: @book.metadata.merge('option_review' => summary))
        summary.symbolize_keys
      end

      private

      # Buyer-facing options of this book with no decision yet.
      def candidates
        known = CatalogOptionDecision.where(manufacturer_id: @mfr).distinct.pluck(:option_key).to_set
        prices = @book.option_prices.includes(option: :group).to_a.uniq(&:catalog_option_id)
        @standard = prices.select(&:is_standard).to_set(&:catalog_option_id)
        prices.map(&:option)
              .select { |o| o.status == 'active' && !known.include?(o.key) && o.group&.name.to_s.match?(BUYER_GROUPS) }
              .sort_by { |o| [o.group&.position.to_i, o.group&.name.to_s, o.name] }
      end

      def prompt(batch)
        lines = batch.map do |o|
          family = Truebuild::OptionFamilies.key(o.name)
          flags = [o.kind, ('standard' if @standard.include?(o.id)), ("set=#{o.metadata['color_set']}" if o.metadata['color_set'].present?),
                   ("family=#{family}" if family)].compact.join(', ')
          "#{o.id} | #{o.group&.name} | #{o.name} | #{flags}"
        end
        <<~TEXT
          #{examples}
          Options from #{@book.manufacturer&.name} #{@book.name}:
          #{lines.join("\n")}
        TEXT
      end

      # The manufacturer's reviewed decisions, newest first: what was kept and
      # what was turned down, so the same mistake is not suggested twice.
      def examples
        rows = CatalogOptionDecision.where(manufacturer_id: @mfr).where.not(reviewed_at: nil).order(reviewed_at: :desc).limit(EXAMPLES).to_a
        return '' if rows.empty?

        names = CatalogOption.where(manufacturer_id: @mfr, key: rows.map(&:option_key)).pluck(:key, :name).to_h
        lines = rows.map do |r|
          "#{r.status == 'rejected' ? 'WRONG' : 'RIGHT'}: #{r.kind} #{r.value} for \"#{names[r.option_key] || r.option_key}\"#{" (#{r.note})" if r.note.present?}"
        end
        "An admin reviewed earlier decisions for this factory. Follow them:\n#{lines.join("\n")}\n"
      end

      # Writes the suggestions as active decisions. Returns how many.
      def record(input, by_id)
        made = 0
        each_decision(input) do |kind, ids, value, reason|
          suggestion = SecureRandom.uuid
          options = ids.filter_map { |id| by_id[id.to_i] }
          next if options.size < (%w[family same_finish].include?(kind) ? 2 : 1)

          options.each do |o|
            CatalogOptionDecision.create!(manufacturer_id: @mfr, option_key: o.key, kind: kind, value: value, source: 'claude',
                                          suggestion: suggestion, note: reason.to_s.first(500), catalog_price_book_id: @book.id)
            made += 1
          rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
            next
          end
        end
        made
      end

      def each_decision(input)
        Array(input['families']).each { |d| yield 'family', Array(d['ids']), d['family'].to_s.downcase.squish, d['reason'] }
        Array(input['not_families']).each { |d| yield 'not_family', Array(d['ids']), nil, d['reason'] }
        Array(input['same_finish']).each { |d| yield 'same_finish', Array(d['ids']), d['show'].to_s.squish, d['reason'] }
        Array(input['color_choices']).each { |d| yield 'color_choice', Array(d['ids']), d['set'].to_s.squish, d['reason'] }
        Array(input['includes']).each { |d| yield 'includes', Array(d['ids']), d['family'].to_s.downcase.squish, d['reason'] }
      end
    end
  end
end
