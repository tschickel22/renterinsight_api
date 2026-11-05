# frozen_string_literal: true

# Help for the phone conversation screen and opt-outs, from
# db/guide/communication_articles.yml. Insert only, by slug; see
# Guide::ArticleLoader. Later edits on staging reach production by the help sync.
class LoadCommunicationHelpArticles < ActiveRecord::Migration[8.0]
  def up
    result = Guide::ArticleLoader.load!(Rails.root.join('db/guide/communication_articles.yml'))
    say "Help articles: #{result.created.size} added, #{result.skipped.size} already there" \
        "#{result.missing_modules.any? ? ", modules missing: #{result.missing_modules.join(', ')}" : ''}"
  end

  def down
    # Articles are content; leave them.
  end
end
