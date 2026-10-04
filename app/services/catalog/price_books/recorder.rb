# frozen_string_literal: true

module Catalog
  module PriceBooks
    # What extractors write through: import items for review, and the model
    # usage for the book (platform work, so it is not billed to a company).
    #
    # Spend is saved on the file after every call, so files read at the same
    # time see each other's spend, and a book stops at its cap
    # (PRICE_BOOK_BUDGET_USD, $15 by default; the Champion package cost ~$5).
    class Recorder
      DEFAULT_BUDGET_USD = 15.0

      attr_reader :input_tokens, :output_tokens, :calls

      def self.budget_usd
        (ENV['PRICE_BOOK_BUDGET_USD'].presence || DEFAULT_BUDGET_USD).to_f
      end

      # Dollars spent reading this book's files so far.
      def self.spent_usd(book)
        book.documents.reload.sum { |d| usage_cost(d.metadata['usage']) + d.metadata['cost_usd_prior_runs'].to_f } +
          usage_cost(book.metadata['review_usage'])
      end

      # Files read before costs were recorded only carry token counts.
      def self.usage_cost(usage)
        return 0.0 unless usage.is_a?(Hash)
        return usage['cost_usd'].to_f if usage.key?('cost_usd')

        ClaudeClient.cost_usd(usage['input_tokens'], usage['output_tokens'])
      end

      def initialize(price_book, client: ClaudeClient, document: nil)
        @book = price_book
        @client = client
        @document = document
        @input_tokens = 0
        @output_tokens = 0
        @calls = 0
      end

      def claude(content:, tool:, system:, max_tokens: 32_000)
        spent = self.class.spent_usd(@book)
        if spent >= self.class.budget_usd
          raise ExtractionError, format('Stopped at the $%.0f spending cap for this price book ($%.2f spent). ' \
                                        'Raise PRICE_BOOK_BUDGET_USD to continue.', self.class.budget_usd, spent)
        end

        r = @client.call(content: content, tool: tool, system: system, max_tokens: max_tokens)
        @calls += 1
        @input_tokens += r[:input_tokens].to_i
        @output_tokens += r[:output_tokens].to_i
        save_usage
        raise ExtractionError, 'The model ran out of room mid-answer; the chunk is too large.' if r[:stop_reason] == 'max_tokens'

        r
      end

      def cost_usd
        ClaudeClient.cost_usd(@input_tokens, @output_tokens)
      end

      def item(document:, item_type:, payload:, source_ref:, flags: [])
        @book.import_items.create!(document: document, item_type: item_type, payload: payload,
                                   source_ref: source_ref, flags: flags)
      end

      # Add a flag to this document's items whose payload matches.
      def flag_items(document, predicate, flag)
        @book.import_items.where(document: document).find_each do |i|
          next unless predicate.call(i.payload)

          i.update!(flags: (i.flags + [flag]).uniq)
        end
      end

      def usage
        { 'calls' => @calls, 'input_tokens' => @input_tokens, 'output_tokens' => @output_tokens,
          'cost_usd' => cost_usd.round(4) }
      end

      private

      def save_usage
        if @document
          @document.update_columns(metadata: @document.reload.metadata.merge('usage' => usage))
        else
          # Review work (second reads) belongs to the book, not a file.
          prior = @book.reload.metadata['review_usage_base'] || {}
          total = { 'calls' => prior['calls'].to_i + @calls,
                    'input_tokens' => prior['input_tokens'].to_i + @input_tokens,
                    'output_tokens' => prior['output_tokens'].to_i + @output_tokens }
          total['cost_usd'] = ClaudeClient.cost_usd(total['input_tokens'], total['output_tokens']).round(4)
          @book.update_columns(metadata: @book.metadata.merge('review_usage' => total))
        end
      end
    end
  end
end
