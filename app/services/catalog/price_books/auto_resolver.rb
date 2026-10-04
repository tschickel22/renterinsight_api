# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Clears the review queue of everything a person does not need to decide.
    #
    # On the Champion Topeka book, 1,816 of 1,900 items had no flag, and 77 of
    # the 84 flags were information or known patterns: O read as zero on a
    # scan, 30' boxes printed as 32 in Champion's model numbers, a length the
    # model name and number both contradict. Each fix is written on the item
    # (payload['resolution']) so the admin can see why it was approved.
    #
    # What remains pending is a real decision: a sheet that contradicts itself
    # with no tiebreak, a value the reader was unsure of, a model that vanished
    # from the new book.
    class AutoResolver
      # Facts about how a value was read, not doubts about the value.
      INFO_FLAGS = %w[
        model_number_normalized scanned_source cost_retail_swapped cost_cell_differs retail_cell_differs
        markup_differs_from_tab not_verbatim duplicate_factory_code catalog_name_conflict
      ].freeze

      Result = Struct.new(:approved, :corrected, :needs_you, :reasons, keyword_init: true)

      def initialize(book, by:, verifier: nil)
        @book = book
        @user = by
        @verifier = verifier
      end

      def call
        result = Result.new(approved: 0, corrected: 0, needs_you: 0, reasons: Hash.new(0))
        @verifier&.call

        @book.import_items.pending.find_each do |item|
          outcome = resolve(item)
          if outcome.nil?
            result.needs_you += 1
            item.flags.reject { |f| INFO_FLAGS.include?(f) }.each { |f| result.reasons[f] += 1 }
            next
          end

          status, payload, note = outcome
          attrs = { review_status: status, reviewed_by: @user, reviewed_at: Time.current }
          attrs[:payload] = note ? payload.merge('resolution' => note) : payload
          item.update!(attrs)
          status == 'edited' ? result.corrected += 1 : result.approved += 1
        end

        summary = result.to_h.merge(reasons: result.reasons.to_h, ran_at: Time.current.iso8601)
        @book.update!(metadata: @book.metadata.merge('auto_resolve' => summary.stringify_keys))
        result
      end

      private

      # [status, payload, note] when the item can be settled, nil when a person must decide.
      def resolve(item)
        return nil if item.change_type == 'removed'

        p = item.payload
        real = item.flags - INFO_FLAGS
        return ['approved', p, info_note(item.flags)] if real.empty?

        notes = [info_note(item.flags)].compact
        real.each do |flag|
          fix = fix_for(flag, p)
          return nil unless fix

          p, note = fix
          notes << note
        end
        [p == item.payload ? 'approved' : 'edited', p, notes.join(' ')]
      end

      def fix_for(flag, p)
        mn = Catalog::ModelNumber.parse(p['model_number'])
        case flag
        when 'model_code_width_mismatch'
          # Champion's numbers carry 32 for a 30' wide box (and 28 for 26').
          if mn.valid? && mn.width_ft - p['width_ft'].to_i == 2 && [30, 26].include?(p['width_ft'].to_i)
            [p, "#{p['width_ft']}' wide boxes are coded #{mn.width_ft} in Champion model numbers; the printed width is kept."]
          end
        when 'model_code_length_mismatch'
          # "48' Lincoln" under 2848…: the name and the number agree, the box column does not.
          named = p['model_name'].to_s[/\A\s*(\d{2})\s*'/, 1].to_i
          if mn.valid? && named == mn.length_ft && named != p['length_ft'].to_i
            [p.merge('length_ft' => named),
             "Length set to #{named}' because the model name and the model number both say #{named}; the sheet's box column said #{p['length_ft']}'."]
          end
        when 'read_uncertain'
          if p['second_read'].is_a?(Hash) && p['second_read']['agrees']
            [p, 'A second read of the page gave the same values.']
          end
        end
      end

      def info_note(flags)
        notes = []
        notes << 'A letter O on the scan was read as zero in the model number.' if flags.include?('model_number_normalized')
        notes << 'Cost and retail were read from swapped columns and put back.' if flags.include?('cost_retail_swapped')
        notes << 'The value from the spreadsheet cell was used.' if (flags & %w[cost_cell_differs retail_cell_differs]).any?
        notes << 'This row uses a different markup from the rest of its tab.' if flags.include?('markup_differs_from_tab')
        notes << 'Not linked to the catalog because the names differ; choose a link below if one is right.' if flags.include?('catalog_name_conflict')
        notes.join(' ').presence
      end
    end
  end
end
