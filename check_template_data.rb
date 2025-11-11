#!/usr/bin/env ruby
require_relative 'config/environment'

puts "\n=== CHECKING TEMPLATE DATA ==="

brochure = Brochure.find_by(public_id: 'xFx3sVlck8Ifg1m3')

if brochure
  puts "\nBrochure ID: #{brochure.id}"
  puts "Title: #{brochure.title}"
  puts "Template Data:"
  pp brochure.template_data
  puts "\nHas blocks? #{brochure.template_data&.key?('blocks')}"
  puts "Blocks count: #{brochure.template_data&.dig('blocks')&.length || 0}"
  
  puts "\n=== FIXING TEMPLATE DATA ==="
  
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
      },
      {
        "id" => "features-1",
        "type" => "features",
        "config" => {
          "title" => "Why Choose Us",
          "features" => [
            "Premium Quality",
            "Competitive Pricing",
            "Expert Support",
            "Customization Available"
          ]
        }
      },
      {
        "id" => "cta-1",
        "type" => "cta",
        "config" => {
          "title" => "Ready to Learn More?",
          "subtitle" => "Contact us today to schedule a viewing",
          "buttonText" => "Get in Touch"
        }
      }
    ]
  }
  
  brochure.update!(template_data: template_data)
  puts "✅ Template data updated"
  
  puts "\nVerifying..."
  brochure.reload
  puts "Has blocks now? #{brochure.template_data&.key?('blocks')}"
  puts "Blocks count: #{brochure.template_data&.dig('blocks')&.length || 0}"
else
  puts "❌ Brochure not found"
end
