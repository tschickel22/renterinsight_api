#!/usr/bin/env ruby
require_relative 'config/environment'

puts "\n=== FIXING BROCHURE TEMPLATE DATA ==="

# Fix the most recent brochure
brochure = Brochure.find_by(public_id: 'TuM6yBKbramr0Txh')

if brochure.nil?
  puts "❌ Brochure not found"
  exit 1
end

puts "Fixing Brochure ID: #{brochure.id}"
puts "Title: #{brochure.title}"
puts "Current template_data: #{brochure.template_data.inspect}"

template_data = {
  "blocks" => [
    {
      "id" => "hero-1",
      "type" => "hero",
      "config" => {
        "title" => brochure.title || "Property Collection",
        "subtitle" => brochure.description || "Explore our featured properties"
      }
    },
    {
      "id" => "gallery-1",
      "type" => "gallery",
      "config" => {
        "title" => "Featured Properties",
        "maxItems" => 15,
        "showPrices" => true,
        "showSpecs" => true,
        "showDescription" => true
      }
    }
  ]
}

brochure.update!(template_data: template_data)
puts "✅ Template data updated with #{template_data['blocks'].length} blocks"

brochure.reload
puts "\nVerifying..."
puts "Has blocks? #{brochure.template_data&.key?('blocks')}"
puts "Blocks count: #{brochure.template_data&.dig('blocks')&.length || 0}"
puts "\n✅ Brochure is ready!"
