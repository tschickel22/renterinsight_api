# Fix script to add template data to existing brochure
# Run with: rails runner fix_brochure_template.rb

public_id = 'WGYLOQvYbPSaYw7J'

puts "\n=== Fixing Brochure Template Data ===\n"

brochure = Brochure.find_by(public_id: public_id)

if brochure.nil?
  puts "❌ Brochure not found!"
  exit 1
end

puts "Found brochure: #{brochure.title}"
puts "Current template_data: #{brochure.template_data.inspect}"

# Create default template with blocks
default_template_data = {
  "name" => "Modern Showcase",
  "blocks" => [
    {
      "id" => "hero-1",
      "type" => "hero",
      "config" => {
        "title" => "Featured Inventory",
        "subtitle" => "Explore our premium selection",
        "backgroundImage" => ""
      }
    },
    {
      "id" => "gallery-1",
      "type" => "gallery",
      "config" => {
        "title" => "Available Units",
        "maxItems" => 6,
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
          "Expert Service",
          "Financing Available"
        ]
      }
    },
    {
      "id" => "cta-1",
      "type" => "cta",
      "config" => {
        "title" => "Ready to Learn More?",
        "subtitle" => "Contact us today for more information",
        "buttonText" => "Get In Touch"
      }
    }
  ]
}

brochure.template_data = default_template_data

if brochure.save
  puts "\n✅ Template data updated successfully!"
  puts "Blocks added: #{brochure.template_data['blocks'].length}"
  brochure.template_data['blocks'].each_with_index do |block, i|
    puts "  #{i+1}. #{block['type']} - #{block['config']['title']}"
  end
else
  puts "\n❌ Failed to update: #{brochure.errors.full_messages.join(', ')}"
end

puts "\n=== Done ===\n"
