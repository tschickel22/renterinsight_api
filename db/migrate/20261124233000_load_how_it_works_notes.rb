# frozen_string_literal: true

# The "How it works" notes for accounting and commissions (E118), from
# db/guide/how_it_works_*.yml. Insert only, by slug; see Guide::ArticleLoader.
class LoadHowItWorksNotes < ActiveRecord::Migration[8.0]
  def up
    %w[how_it_works_accounting how_it_works_commissions].each do |file|
      result = Guide::ArticleLoader.load!(Rails.root.join("db/guide/#{file}.yml"))
      say "#{file}: #{result.created.size} added, #{result.skipped.size} already there" \
          "#{result.missing_modules.any? ? ", modules missing: #{result.missing_modules.join(', ')}" : ''}"
    end
  end

  def down
    # Articles are content; leave them.
  end
end
