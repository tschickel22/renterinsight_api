# frozen_string_literal: true

module Guide
  # Loads help articles kept in code (db/guide/*.yml) into knowledge_articles
  # (backlog E88), so staging and production get the same text from a
  # migration instead of being typed into Knowledge admin twice.
  #
  # Insert only: an article whose slug already exists is left as it is, so an
  # edit made in Knowledge admin is never overwritten by a later deploy. To
  # replace text that is already loaded, change it in Knowledge admin, or give
  # the article a new slug and list the old one under `supersedes`.
  #
  # `supersedes` lists older slugs the file replaces; those are unpublished,
  # never deleted.
  class ArticleLoader
    Result = Struct.new(:created, :skipped, :unpublished, :missing_modules, keyword_init: true)

    def self.load!(path)
      new(YAML.safe_load_file(path)).load!
    end

    def initialize(data)
      @data = data || {}
    end

    def load!
      result = Result.new(created: [], skipped: [], unpublished: [], missing_modules: [])
      Array(@data['articles']).each do |a|
        mod = Knowledge::Module.find_by(key: a['module'])
        unless mod
          result.missing_modules << a['module']
          next
        end
        if Knowledge::Article.exists?(slug: a['slug'])
          result.skipped << a['slug']
          next
        end

        Knowledge::Article.create!(
          knowledge_module: mod, slug: a['slug'], title: a['title'], excerpt: a['excerpt'],
          content: a['content'], article_type: a['article_type'] || 'how_to',
          position: a['position'].to_i, is_published: true
        )
        result.created << a['slug']
      end

      Array(@data['supersedes']).each do |slug|
        n = Knowledge::Article.where(slug: slug, is_published: true).update_all(is_published: false, updated_at: Time.current)
        result.unpublished << slug if n.positive?
      end
      result.missing_modules.uniq!
      result
    end
  end
end
