# frozen_string_literal: true

module Catalog
  module PriceBooks
    # What extractors write through: import items for review, and the model
    # usage for the book (platform work, so it is not billed to a company).
    class Recorder
      attr_reader :input_tokens, :output_tokens, :calls

      def initialize(price_book, client: ClaudeClient)
        @book = price_book
        @client = client
        @input_tokens = 0
        @output_tokens = 0
        @calls = 0
      end

      def claude(content:, tool:, system:, max_tokens: 32_000)
        r = @client.call(content: content, tool: tool, system: system, max_tokens: max_tokens)
        @calls += 1
        @input_tokens += r[:input_tokens].to_i
        @output_tokens += r[:output_tokens].to_i
        raise ExtractionError, 'The model ran out of room mid-answer; the chunk is too large.' if r[:stop_reason] == 'max_tokens'

        r
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
        { 'calls' => @calls, 'input_tokens' => @input_tokens, 'output_tokens' => @output_tokens }
      end
    end
  end
end
