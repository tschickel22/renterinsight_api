# frozen_string_literal: true

# The "Delete a deal" help article, from db/guide/deal_delete_article.yml.
# Insert only, by slug; see Guide::ArticleLoader.
class LoadDealDeleteHelpArticle < ActiveRecord::Migration[8.0]
  def up
    result = Guide::ArticleLoader.load!(Rails.root.join('db/guide/deal_delete_article.yml'))
    say "Help articles: #{result.created.size} added, #{result.skipped.size} already there" \
        "#{result.missing_modules.any? ? ", modules missing: #{result.missing_modules.join(', ')}" : ''}"
  end

  def down
    # Articles are content; leave them.
  end
end
