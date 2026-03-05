# frozen_string_literal: true
# =============================================================================
# Import Floor Plan Assets from manifest.json (S3 upload metadata)
# Run: bin/rails runner "load 'db/seeds/import_from_manifest.rb'"
# =============================================================================

require 'json'

puts "[Manifest Import] Starting import from manifest.json..."

# The Manufacturer model references columns (contact_name, city, company_id,
# etc.) that haven't been migrated yet. Patch the methods that fail.
unless Manufacturer.column_names.include?('company_id')
  Manufacturer.class_eval do
    def normalize_fields
      self.name = name&.strip
      self.code = code&.strip&.upcase if code.present?
      self.contact_email = contact_email&.strip&.downcase if contact_email.present?
      self.contact_phone = contact_phone&.strip if contact_phone.present?
    end

    def company_id?
      false
    end
  end
  puts "[Manifest Import] Patched Manufacturer for missing columns"
end

manifest_path = Rails.root.join('manifest.json')
unless File.exist?(manifest_path)
  puts "[Manifest Import] ERROR: manifest.json not found at #{manifest_path}"
  exit 1
end

manifest = JSON.parse(File.read(manifest_path))
files = manifest['files']
puts "[Manifest Import] Loaded #{files.size} file entries"

# ---------------------------------------------------------------------------
# 1. Manufacturers
# ---------------------------------------------------------------------------
BRAND_TO_MANUFACTURER = {
  'champion-homes' => 'Champion Homes',
  'Champion Homes'  => 'Champion Homes',
  'Redman Homes'    => 'Redman Homes',
  'Dutch Housing'   => 'Dutch Housing',
}.freeze

MANUFACTURER_ATTRS = {
  'Champion Homes' => { code: 'CHAMP',  website: 'https://www.championhomes.com' },
  'Redman Homes'   => { code: 'REDMAN', website: 'https://www.redmanhomes.com' },
  'Dutch Housing'  => { code: 'DUTCH',  website: 'https://www.dutchhousing.com' },
}.freeze

manufacturers = {}
MANUFACTURER_ATTRS.each do |name, attrs|
  m = Manufacturer.find_or_initialize_by(name: name)
  m.assign_attributes(
    industry_type: 'manufactured_home',
    active: true,
    code: attrs[:code],
    website: attrs[:website]
  )
  m.save!
  manufacturers[name] = m
  puts "[Manifest Import] Manufacturer: #{m.name} (id=#{m.id})"
end

# ---------------------------------------------------------------------------
# 2. Factory
# ---------------------------------------------------------------------------
# All manifest entries reference topeka-in factory
champion = manufacturers['Champion Homes']
factory = Factory.find_or_initialize_by(manufacturer: champion, code: 'TOPEKA-IN')
factory.assign_attributes(
  name: 'Champion - Topeka',
  city: 'Topeka',
  state: 'IN',
  zip: '46571',
  is_active: true
)
factory.save!
puts "[Manifest Import] Factory: #{factory.name} (id=#{factory.id})"

# Also associate factory with other manufacturers (they share the plant)
[manufacturers['Redman Homes'], manufacturers['Dutch Housing']].each do |mfr|
  f = Factory.find_or_initialize_by(manufacturer: mfr, code: 'TOPEKA-IN')
  f.assign_attributes(
    name: "#{mfr.name} - Topeka",
    city: 'Topeka',
    state: 'IN',
    zip: '46571',
    is_active: true
  )
  f.save!
  puts "[Manifest Import] Factory: #{f.name} (id=#{f.id})"
end

# ---------------------------------------------------------------------------
# 3. Categorize folder_type into asset categories
# ---------------------------------------------------------------------------
def categorize_folder_type(folder_type, content_type)
  case folder_type
  when 'web'
    'web'
  when 'jpgs', 'jpg'
    'gallery'
  when 'videos', 'video'
    'video'
  when 'renderings'
    'rendering'
  when 'literature'
    'literature'
  else
    # Model-specific subfolders — categorize by content_type
    if content_type&.start_with?('video/')
      'video'
    else
      'gallery'
    end
  end
end

# ---------------------------------------------------------------------------
# 4. Group files by (manufacturer, series, model) → floor plans
# ---------------------------------------------------------------------------
grouped = files.group_by { |f|
  mfr_name = BRAND_TO_MANUFACTURER[f['brand']]
  [mfr_name, f['series'], f['model']]
}

puts "[Manifest Import] Found #{grouped.size} unique floor plan groups"

created = 0
updated = 0
skipped = 0

grouped.each do |(mfr_name, series, model), entries|
  unless mfr_name
    puts "[Manifest Import] SKIP: Unknown brand '#{entries.first['brand']}'"
    skipped += entries.size
    next
  end

  manufacturer = manufacturers[mfr_name]

  # Build model_code: prefer model_num from entries if available and meaningful
  model_nums = entries.map { |e| e['model_num'] }.compact.uniq
  model_num = model_nums.reject { |n| n == '112' || n.to_s.empty? }.first || model_nums.first

  # Construct a unique model_code within this manufacturer
  model_code = if model_num && model_num != '112'
                 "#{model_num}-#{model}".upcase
               else
                 "#{series}-#{model}".upcase
               end

  # Humanize the name
  name = model.to_s.split('-').map(&:capitalize).join(' ')
  name = "#{name} (#{series.split('-').map(&:capitalize).join(' ')})" if series != model

  # Build images_array with structured metadata
  images_array = entries.map { |entry|
    {
      'url'          => entry['s3_url'],
      's3_key'       => entry['s3_key'],
      'filename'     => entry['filename'],
      'category'     => categorize_folder_type(entry['folder_type'], entry['content_type']),
      'content_type' => entry['content_type'],
      'size'         => entry['size'],
      'folder_type'  => entry['folder_type'],
    }
  }.sort_by { |img| [img['category'], img['filename']] }

  # Find the factory for this manufacturer
  mfr_factory = Factory.find_by(manufacturer: manufacturer, code: 'TOPEKA-IN')

  floor_plan = FloorPlan.find_or_initialize_by(
    manufacturer: manufacturer,
    model_code: model_code
  )

  is_new = floor_plan.new_record?

  floor_plan.assign_attributes(
    name: name,
    series: series,
    factory: mfr_factory,
    images_array: images_array,
    is_active: true
  )

  floor_plan.save!
  is_new ? (created += 1) : (updated += 1)

  web_count     = images_array.count { |i| i['category'] == 'web' }
  gallery_count = images_array.count { |i| i['category'] == 'gallery' }
  video_count   = images_array.count { |i| i['category'] == 'video' }

  puts "[Manifest Import] #{is_new ? 'CREATED' : 'UPDATED'}: #{manufacturer.name} / #{floor_plan.name} " \
       "(#{model_code}) — #{web_count} web, #{gallery_count} gallery, #{video_count} video"
end

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
puts ""
puts "[Manifest Import] ============================================"
puts "[Manifest Import] Done! Created: #{created}, Updated: #{updated}, Skipped files: #{skipped}"
manufacturers.each do |name, mfr|
  count = FloorPlan.where(manufacturer: mfr).count
  assets = FloorPlan.where(manufacturer: mfr).sum { |fp| fp.images_array&.size || 0 }
  puts "[Manifest Import]   #{name}: #{count} floor plans, #{assets} total assets"
end
puts "[Manifest Import] ============================================"
