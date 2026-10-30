# frozen_string_literal: true

# Project management help articles (backlog E88), from db/guide/project_articles.yml.
# Insert only, by slug; see Guide::ArticleLoader. A database without the
# projects or contractors knowledge module simply gets none of them.
class LoadProjectHelpArticles < ActiveRecord::Migration[8.0]
  def up
    result = Guide::ArticleLoader.load!(Rails.root.join('db/guide/project_articles.yml'))
    say "Help articles: #{result.created.size} added, #{result.skipped.size} already there, " \
        "#{result.unpublished.size} superseded#{result.missing_modules.any? ? ", modules missing: #{result.missing_modules.join(', ')}" : ''}"
  end

  def down
    # Articles are content; leave them.
  end
end
