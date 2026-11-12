# frozen_string_literal: true

# QuickBooks switch help articles (backlog E62, E101), from
# db/guide/quickbooks_switch_articles.yml. Insert only, by slug; see
# Guide::ArticleLoader. A database without the accounting knowledge module
# simply gets none of them.
class LoadQuickbooksSwitchHelpArticles < ActiveRecord::Migration[8.0]
  def up
    result = Guide::ArticleLoader.load!(Rails.root.join('db/guide/quickbooks_switch_articles.yml'))
    say "Help articles: #{result.created.size} added, #{result.skipped.size} already there, " \
        "#{result.unpublished.size} superseded#{result.missing_modules.any? ? ", modules missing: #{result.missing_modules.join(', ')}" : ''}"
  end

  def down
    # Articles are content; leave them.
  end
end
