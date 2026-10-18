# frozen_string_literal: true

namespace :truebuild do
  # Loads a factory line without prices from a spec in the private bucket
  # (Catalog::UnpricedLine), then links lot homes of the line by name.
  #   bin/rails 'truebuild:load_unpriced_line[s3://bucket/catalog-specs/0/timber-creek.json]'
  desc 'Load a factory line without prices from a spec, and link its lot homes by name'
  task :load_unpriced_line, [:ref] => :environment do |_, args|
    spec = JSON.parse(PrivateFiles.read(args[:ref]))
    result = Catalog::UnpricedLine.load!(spec)
    puts "Loaded #{result[:manufacturer].name} / #{result[:factory].name}: #{result[:models]} models, " \
         "#{result[:options]} finishes, #{result[:swatches]} decor samples (book #{result[:book].id})"
    linked = Truebuild::HomeMatcher.new.link_by_name_all(Vehicle.where(is_deleted: [false, nil]))
    linked.each { |id, number| puts "vehicle #{id} -> #{number}" }
    puts "Linked #{linked.size} homes by name"
  end
end
