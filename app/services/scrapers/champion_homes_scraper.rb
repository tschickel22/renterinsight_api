# frozen_string_literal: true

# DEPRECATED: Use Scrapers::ChampionImsClient instead.
#
# This Selenium-based scraper targets the old championhomes.com listing
# pages and is being phased out in favor of the Champion IMS JSON feed
# (see app/services/scrapers/champion_ims_client.rb and champion_ims_sync_service.rb).
#
# The IMS feed is faster (no browser), more reliable (structured JSON),
# and supports per-retailer filtering via Navision ID. Do not remove this
# file yet - it may still be referenced by legacy scripts.

require 'selenium-webdriver'

module Scrapers
  class ChampionHomesScraper
    BASE_URL = 'https://www.championhomes.com'
    FLOOR_PLANS_URL = "#{BASE_URL}/manufactured-homes/home-center"

    def initialize
      @manufacturer = Manufacturer.find_or_create_by!(name: 'Champion Homes') do |m|
        m.industry_type = 'manufactured_homes'
        m.website = BASE_URL
        m.active = true
        m.scraper_enabled = true
      end

      # Set code if not already set (column may have been added after initial creation)
      @manufacturer.update!(code: 'CHAMPION') if @manufacturer.code.blank?

      @driver = setup_driver
    end

    def scrape_all
      Rails.logger.info "[Champion Scraper] Starting scrape"

      begin
        scrape_factories
        scrape_floor_plans

        @manufacturer.update!(last_scraped_at: Time.current)
        Rails.logger.info "[Champion Scraper] Scrape complete"
      rescue => e
        Rails.logger.error "[Champion Scraper] Error: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
      ensure
        @driver&.quit
      end
    end

    private

    def setup_driver
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument('--headless')
      options.add_argument('--no-sandbox')
      options.add_argument('--disable-dev-shm-usage')
      options.add_argument('--window-size=1920,1080')
      options.add_argument('--disable-gpu')

      Selenium::WebDriver.for :chrome, options: options
    end

    def scrape_factories
      factories_data = [
        { code: 'MER', name: 'Meridian Factory', city: 'Meridian', state: 'ID', zip: '83642' },
        { code: 'RED', name: 'Redman Homes', city: 'Silverton', state: 'OR', zip: '97381' },
        { code: 'YORK', name: 'York Factory', city: 'York', state: 'NE', zip: '68467' },
        { code: 'LAKE', name: 'Lake City Factory', city: 'Lake City', state: 'FL', zip: '32025' },
        { code: 'SALIS', name: 'Salisbury Factory', city: 'Salisbury', state: 'NC', zip: '28144' }
      ]

      factories_data.each do |data|
        Factory.find_or_create_by!(
          manufacturer: @manufacturer,
          code: data[:code]
        ) do |f|
          f.name = data[:name]
          f.city = data[:city]
          f.state = data[:state]
          f.zip = data[:zip]
          f.is_active = true
        end
      end

      Rails.logger.info "[Champion Scraper] #{factories_data.size} factories seeded"
    end

    def scrape_floor_plans
      @driver.navigate.to FLOOR_PLANS_URL
      sleep 3

      plan_links = @driver.find_elements(css: '.home-card a, .floorplan-link, .home-listing a')

      Rails.logger.info "[Champion Scraper] Found #{plan_links.count} floor plan links"

      urls = plan_links.map { |link| link.attribute('href') }.compact.uniq
      urls = urls.select { |url| url.include?('championhomes.com') }

      urls.take(15).each_with_index do |url, index|
        begin
          scrape_floor_plan_detail(url, index)
          sleep 2
        rescue => e
          Rails.logger.error "[Champion Scraper] Error on plan #{index}: #{e.message}"
        end
      end
    end

    def scrape_floor_plan_detail(url, index)
      Rails.logger.info "[Champion Scraper] Scraping #{index + 1}: #{url}"

      @driver.navigate.to url
      sleep 2

      name = safe_find_text('.home-title, h1.title, .floorplan-name, h1')
      return if name.blank?

      model_code = extract_model_code(name, url)

      specs = extract_specs
      images = scrape_images
      pricing = scrape_pricing

      floor_plan = FloorPlan.find_or_initialize_by(
        manufacturer: @manufacturer,
        model_code: model_code
      )

      floor_plan.assign_attributes(
        name: name,
        beds: specs[:beds],
        baths: specs[:baths],
        sqft: specs[:sqft],
        width_feet: specs[:width],
        length_feet: specs[:length],
        specifications: specs,
        images_array: images,
        base_price_low: pricing[:base_low],
        base_price_high: pricing[:base_high],
        suggested_retail_low: pricing[:retail_low],
        suggested_retail_high: pricing[:retail_high],
        is_active: true,
        scraper_source_url: url,
        last_scraped_at: Time.current
      )

      if floor_plan.save
        scrape_options_for_floor_plan(floor_plan)
        Rails.logger.info "[Champion Scraper] Saved: #{floor_plan.name} (#{floor_plan.model_code})"
      else
        Rails.logger.error "[Champion Scraper] Failed to save: #{floor_plan.errors.full_messages}"
      end
    end

    def extract_specs
      page_text = @driver.find_element(tag_name: 'body').text rescue ''

      {
        beds: extract_number(page_text, /(\d+)\s*(bed|bd)/i),
        baths: extract_decimal(page_text, /(\d+\.?\d*)\s*(bath|ba)/i),
        sqft: extract_number(page_text, /(\d[\d,]*)\s*sq/i),
        width: extract_decimal(page_text, /(\d+)['\s]*(?:x|w)/i),
        length: extract_decimal(page_text, /x\s*(\d+)['\s]*/i)
      }
    end

    def scrape_images
      image_elements = @driver.find_elements(css: '.gallery img, .home-images img, .slider img, .carousel img')

      images = image_elements.filter_map do |img|
        src = img.attribute('src') || img.attribute('data-src')
        next nil if src.blank?
        src.gsub(/thumb|small/, 'large')
      end.uniq

      images.presence || []
    end

    def scrape_pricing
      price_text = safe_find_text('.price, .pricing, .home-price')

      if price_text =~ /\$?([\d,]+)\s*[-–]\s*\$?([\d,]+)/
        base_low = $1.gsub(',', '').to_i
        base_high = $2.gsub(',', '').to_i

        {
          base_low: base_low,
          base_high: base_high,
          retail_low: (base_low * 1.15).round(-2),
          retail_high: (base_high * 1.15).round(-2)
        }
      elsif price_text =~ /\$?([\d,]+)/
        price = $1.gsub(',', '').to_i
        {
          base_low: price,
          base_high: price,
          retail_low: (price * 1.15).round(-2),
          retail_high: (price * 1.15).round(-2)
        }
      else
        { base_low: 65_000, base_high: 95_000, retail_low: 75_000, retail_high: 110_000 }
      end
    end

    def scrape_options_for_floor_plan(floor_plan)
      option_sections = @driver.find_elements(css: '.options-section, .customizations, .design-options')

      option_sections.each_with_index do |section, idx|
        category_name = safe_find_text_in_element(section, '.section-title, h3, h4') || "Options #{idx + 1}"

        category = OptionCategory.find_or_create_by!(
          floor_plan: floor_plan,
          name: category_name
        ) do |cat|
          cat.display_order = idx
          cat.is_required = false
          cat.allow_multiple_selections = false
        end

        option_items = section.find_elements(css: '.option-item, .choice, li')

        option_items.each_with_index do |item, opt_idx|
          option_name = item.text&.strip
          next if option_name.blank? || option_name.length > 255

          FloorPlanOption.find_or_create_by!(
            option_category: category,
            name: option_name.truncate(255)
          ) do |opt|
            opt.price_impact_low = 500
            opt.price_impact_high = 1500
            opt.display_order = opt_idx
          end
        end
      end
    end

    # Helper methods

    def safe_find_text(selector)
      @driver.find_element(css: selector).text
    rescue Selenium::WebDriver::Error::NoSuchElementError
      nil
    end

    def safe_find_text_in_element(element, selector)
      element.find_element(css: selector).text
    rescue Selenium::WebDriver::Error::NoSuchElementError
      nil
    end

    def extract_number(text, regex)
      match = text.match(regex)
      return nil unless match
      match.captures.first.gsub(',', '').to_i
    end

    def extract_decimal(text, regex)
      match = text.match(regex)
      return nil unless match
      match.captures.first.to_f
    end

    def extract_model_code(name, url)
      if name =~ /([A-Z]{2,}-?\d+[A-Z]*\d*)/
        $1
      else
        url.split('/').last&.parameterize&.upcase&.first(20) || "CHAMP-#{SecureRandom.hex(3).upcase}"
      end
    end
  end
end
