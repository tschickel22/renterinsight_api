# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module Knowledge
  # Thin wrapper around the OpenAI embeddings endpoint + pgvector similarity
  # search over knowledge_articles.embedding.
  #
  # Intentionally does NOT call OpenAI from initializers or at boot — embeddings
  # are generated lazily when .generate is invoked (usually from a background
  # job after article create/update, or from SmartSearchService on a miss).
  #
  # Configure with env:
  #   OPENAI_API_KEY   (required for .generate)
  #   OPENAI_EMBEDDINGS_MODEL (default: text-embedding-3-small, 1536 dims)
  class EmbeddingService
    class ConfigurationError < StandardError; end
    class ApiError < StandardError; end

    DEFAULT_MODEL       = 'text-embedding-3-small'
    EMBEDDINGS_ENDPOINT = 'https://api.openai.com/v1/embeddings'

    class << self
      # Returns a Float array of length 1536, or nil on any failure (caller
      # decides whether to raise; we log + swallow so search never hard-fails
      # on a transient OpenAI outage).
      def generate(text)
        return nil if text.to_s.strip.empty?

        api_key = ENV['OPENAI_API_KEY']
        raise ConfigurationError, 'OPENAI_API_KEY not set' if api_key.blank?

        model = ENV.fetch('OPENAI_EMBEDDINGS_MODEL', DEFAULT_MODEL)
        body  = { model: model, input: text.to_s.strip }.to_json

        uri = URI(EMBEDDINGS_ENDPOINT)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = 30

        req = Net::HTTP::Post.new(uri)
        req['Authorization'] = "Bearer #{api_key}"
        req['Content-Type']  = 'application/json'
        req.body = body

        resp = http.request(req)
        unless resp.is_a?(Net::HTTPSuccess)
          raise ApiError, "OpenAI embeddings error #{resp.code}: #{resp.body&.slice(0, 300)}"
        end

        JSON.parse(resp.body).dig('data', 0, 'embedding')
      rescue ConfigurationError => e
        Rails.logger.warn("[Knowledge::EmbeddingService] #{e.message}")
        nil
      rescue ApiError, JSON::ParserError, SocketError, Timeout::Error => e
        Rails.logger.error("[Knowledge::EmbeddingService] #{e.class}: #{e.message}")
        nil
      end

      # pgvector cosine-distance nearest-neighbor search.
      # Returns published articles ordered by similarity (closest first).
      def search(embedding, limit: 5)
        return Knowledge::Article.none if embedding.blank?

        Knowledge::Article
          .published
          .where.not(embedding: nil)
          .nearest_neighbors(:embedding, embedding, distance: 'cosine')
          .limit(limit)
      rescue NoMethodError
        # `nearest_neighbors` comes from the `neighbor` gem via has_neighbors.
        # If the gem is missing or the table has no vector column yet, degrade
        # gracefully to an empty result rather than crashing the search path.
        Rails.logger.warn('[Knowledge::EmbeddingService] has_neighbors not available; returning empty result')
        Knowledge::Article.none
      end

      # Regenerate the embedding for an article after create/update. The input
      # is a concatenation of title + excerpt + content so the vector captures
      # both the hook and the body.
      def update_article(article)
        return unless article.is_a?(Knowledge::Article)

        text = [article.title, article.excerpt, article.content].compact.join("\n\n")
        vector = generate(text)
        return nil if vector.nil?

        article.update_column(:embedding, vector)
        vector
      end
    end
  end
end
