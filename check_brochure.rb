#!/usr/bin/env ruby
require_relative 'config/environment'

puts "\n=== BROCHURE DATABASE CHECK ==="

# Find all brochures
brochures = Brochure.where(company_id: 1).order(created_at: :desc).limit(5)

brochures.each do |b|
  puts "\n--- Brochure ID: #{b.id} ---"
  puts "Title: #{b.title}"
  puts "Public ID: #{b.public_id}"
  puts "Template Name: #{b.template_name}"
  puts "Template Data Class: #{b.template_data.class}"
  puts "Template Data Content:"
  pp b.template_data
  puts "\nVehicle IDs: #{b.vehicle_ids.inspect}"
  puts "Vehicle Count: #{b.vehicles.count}"
end

puts "\n=== ATTEMPTING TO FIX FIRST BROCHURE ==="
brochure = Brochure.where(company_id: 1).first

if brochure
  puts "Fixing Brochure ID: #{brochure.id}"
  
  # Create a proper template structure
  template_data = {
    "blocks" => [
      {
        "id" => "hero-1",
        "type" => "hero",
        "config" => {
          "title" => brochure.title || "Winter Cruiser",
          "subtitle" => brochure.description || "Test description"
        }
      },
      {
        "id" => "gallery-1",
        "type" => "gallery",
        "config" => {
          "title" => "Featured Units",
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
  puts "✅ Updated brochure with template structure"
  puts "New template_data:"
  pp brochure.reload.template_data
else
  puts "❌ No brochures found for company 1"
end
