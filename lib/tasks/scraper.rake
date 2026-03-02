# frozen_string_literal: true

namespace :scraper do
  desc "Scrape Champion Homes floor plans"
  task champion: :environment do
    puts "Starting Champion Homes scraper..."
    Scrapers::ChampionHomesScraper.new.scrape_all
    puts "Scraper complete!"
    puts "Floor plans: #{FloorPlan.count}"
    puts "Option categories: #{OptionCategory.count}"
    puts "Floor plan options: #{FloorPlanOption.count}"
  end

  desc "Scrape all manufacturers"
  task all: :environment do
    Rake::Task['scraper:champion'].invoke
  end
end
