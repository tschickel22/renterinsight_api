# frozen_string_literal: true

# The "People on a deal" help article, from db/guide/deal_people_articles.yml.
# The deal page's Buyers card links to it. Insert only, by slug; see
# Guide::ArticleLoader. A database without the deals knowledge module gets none.
class LoadDealPeopleHelpArticle < ActiveRecord::Migration[8.0]
  def up
    result = Guide::ArticleLoader.load!(Rails.root.join('db/guide/deal_people_articles.yml'))
    say "Help articles: #{result.created.size} added, #{result.skipped.size} already there" \
        "#{result.missing_modules.any? ? ", modules missing: #{result.missing_modules.join(', ')}" : ''}"
  end

  def down
    # Articles are content; leave them.
  end
end
