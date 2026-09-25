# frozen_string_literal: true

module Websites
  # The question-and-answer pairs in a post's own HTML.
  #
  # Blog posts carry their FAQ as a visible section, a "Frequently asked
  # questions" heading followed by one h3 per question and the paragraphs that
  # answer it, because that is what readers see and FAQ markup has to describe
  # visible content. Reading it back out of the HTML means an edit to the post
  # can never leave the markup saying something the page does not.
  module FaqExtractor
    HEADING = /\A\s*(frequently asked questions|faqs?|common questions)\s*\z/i

    module_function

    # @return [Array<Array(String, String)>] [[question, answer], ...]
    def from_html(html)
      return [] if html.blank?

      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      start = doc.css('h2, h3').detect { |h| h.text.match?(HEADING) }
      return [] unless start

      pairs = []
      question = nil
      answer = +''
      node = start.next_element
      while node
        break if node.name == 'h2' || (start.name == 'h3' && node.name == 'h3' && node.text.match?(HEADING))

        if %w[h3 h4].include?(node.name)
          pairs << [question, answer.squish] if question && answer.present?
          question = node.text.squish
          answer = +''
        elsif question
          answer << ' ' << node.text
        end
        node = node.next_element
      end
      pairs << [question, answer.squish] if question && answer.present?
      pairs.reject { |q, a| q.blank? || a.blank? }
    end
  end
end
