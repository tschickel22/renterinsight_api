# frozen_string_literal: true

# How it works notes for every remaining plan module (E118), from
# db/guide/how_it_works_{crm_sales,inventory_service,marketing,finance_management,admin}.yml.
# Insert only, by slug; see Guide::ArticleLoader.
class LoadModuleHowItWorksNotes < ActiveRecord::Migration[8.0]
  FILES = %w[crm_sales inventory_service marketing finance_management admin].freeze

  def up
    FILES.each do |name|
      result = Guide::ArticleLoader.load!(Rails.root.join("db/guide/how_it_works_#{name}.yml"))
      say "#{name}: #{result.created.size} added, #{result.skipped.size} already there" \
          "#{result.missing_modules.any? ? ", modules missing: #{result.missing_modules.join(', ')}" : ''}"
    end
  end

  def down
    # Articles are content; leave them.
  end
end
