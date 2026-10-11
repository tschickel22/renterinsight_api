# frozen_string_literal: true

module Guide
  # Article lookup for the help assistant: the published articles that share
  # the most words with the question, with enough of each body to answer from.
  # Keyword based until an embedding provider is chosen (the pgvector column
  # on knowledge_articles is waiting for it).
  class HelpSearch
    STOP = Knowledge::SmartSearchService::STOP_WORDS

    def self.call(query, limit: 4)
      terms = query.to_s.downcase.scan(/[a-z0-9&]+/).reject { |w| w.length < 3 || STOP.include?(w) }.uniq.first(6)
      return [] if terms.empty?

      clauses = terms.map { '(title ILIKE ? OR excerpt ILIKE ? OR content ILIKE ?)' }
      binds = terms.flat_map { |t| ["%#{Knowledge::Article.sanitize_sql_like(t)}%"] * 3 }
      candidates = Knowledge::Article.published.where.not(article_type: 'release_note')
                                     .where(clauses.join(' OR '), *binds).limit(40)

      candidates.map do |a|
        title = a.title.to_s.downcase
        body = "#{a.excerpt} #{a.content}".downcase
        score = terms.sum { |t| (title.include?(t) ? 3 : 0) + (body.include?(t) ? 1 : 0) }
        [a, score]
      end.sort_by { |_, s| -s }.first(limit).map(&:first)
    end
  end
end
