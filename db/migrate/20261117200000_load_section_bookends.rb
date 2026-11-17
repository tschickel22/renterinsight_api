# frozen_string_literal: true

# The written words around each training area's Watch all, from
# db/guide/section_bookends.yml. Insert only, by slug; see Guide::ArticleLoader.
class LoadSectionBookends < ActiveRecord::Migration[8.0]
  def up
    result = Guide::ArticleLoader.load!(Rails.root.join('db/guide/section_bookends.yml'))
    say "Section bookends: #{result.created.size} added, #{result.skipped.size} already there"
  end

  def down
    # Articles are content; leave them.
  end
end
