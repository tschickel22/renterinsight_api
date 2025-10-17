#!/usr/bin/env ruby
# Run with: ruby create_test_vehicles.rb

require File.expand_path('../config/environment', __FILE__)

puts "Creating test vehicles..."

makes_models = {
  'Ford' => ['F-150', 'F-250', 'Ranger', 'Expedition', 'Explorer'],
  'Chevrolet' => ['Silverado 1500', 'Silverado 2500HD', 'Colorado', 'Tahoe', 'Suburban'],
  'RAM' => ['1500', '2500', '3500', 'ProMaster', 'Promaster City'],
  'Toyota' => ['Tundra', 'Tacoma', 'Sequoia', 'Highlander', '4Runner'],
  'Honda' => ['Ridgeline', 'Pilot', 'CR-V', 'Accord', 'Civic'],
  'GMC' => ['Sierra 1500', 'Sierra 2500HD', 'Canyon', 'Yukon', 'Acadia']
}

conditions = ['new', 'used']
statuses = ['available', 'sold', 'pending', 'reserved']
colors = ['White', 'Black', 'Silver', 'Blue', 'Red', 'Gray', 'Green', 'Brown']
trims = ['Base', 'XL', 'XLT', 'Lariat', 'Limited', 'Platinum', 'King Ranch']

50.times do |i|
  make = makes_models.keys.sample
  model = makes_models[make].sample
  year = rand(2018..2025)
  condition = year >= 2023 ? 'new' : conditions.sample
  
  Vehicle.create!(
    stock_number: "VEH-#{1000 + i}",
    vin: "1HGBH41JXMN#{sprintf('%06d', i)}",
    year: year,
    make: make,
    model: model,
    trim: trims.sample,
    color: colors.sample,
    condition: condition,
    status: statuses.sample,
    price: rand(25_000..85_000),
    cost: rand(20_000..70_000),
    mileage: condition == 'new' ? 0 : rand(5_000..50_000),
    description: "#{year} #{make} #{model} in excellent condition. #{condition == 'new' ? 'Brand new vehicle' : "Used vehicle with #{rand(1..3)} previous owners"}.",
    features: ['Bluetooth', 'Backup Camera', 'Cruise Control', 'Power Windows', 'Leather Seats', 'Sunroof', 'Navigation', 'Apple CarPlay', 'Android Auto'].sample(rand(3..6)),
    location: ['Main Lot', 'North Lot', 'Service Bay', 'Showroom'].sample,
    date_in_stock: rand(180).days.ago
  )
end

puts "Created #{Vehicle.count} vehicles"
puts "\nVehicle Stats:"
puts "- Available: #{Vehicle.available.count}"
puts "- New: #{Vehicle.where(condition: 'new').count}"
puts "- Used: #{Vehicle.where(condition: 'used').count}"
puts "- Total Value: $#{Vehicle.sum(:price).to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
