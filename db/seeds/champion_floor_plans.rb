# frozen_string_literal: true
# =============================================================================
# Champion Homes Floor Plan Seed
# Run: bin/rails runner "load 'db/seeds/champion_floor_plans.rb'"
# =============================================================================

puts "[Seed] Starting Champion Homes floor plan seed..."

# ---------------------------------------------------------------------------
# 1. Manufacturer
# ---------------------------------------------------------------------------
manufacturer = Manufacturer.find_or_create_by!(name: 'Champion Homes') do |m|
  m.active   = true
  m.website  = 'https://www.championhomes.com'
  m.code     = 'CHAMP'
end
puts "[Seed] Manufacturer: #{manufacturer.name} (id=#{manufacturer.id})"

# ---------------------------------------------------------------------------
# 2. Factories (Indiana is Champion's primary manufacturing state)
# ---------------------------------------------------------------------------
factories = {
  indiana: Factory.find_or_create_by!(name: 'Champion - Claypool', manufacturer: manufacturer) { |f|
    f.city = 'Claypool'; f.state = 'IN'; f.zip = '46510'
  },
  texas: Factory.find_or_create_by!(name: 'Champion - Ft. Worth', manufacturer: manufacturer) { |f|
    f.city = 'Fort Worth'; f.state = 'TX'; f.zip = '76179'
  },
  pennsylvania: Factory.find_or_create_by!(name: 'Champion - Lewistown', manufacturer: manufacturer) { |f|
    f.city = 'Lewistown'; f.state = 'PA'; f.zip = '17044'
  },
}
puts "[Seed] Factories: #{factories.keys.join(', ')}"

# ---------------------------------------------------------------------------
# 3. Floor Plans
# Specs are representative of real Champion models.
# Images use Champion's Scene7 CDN pattern — placeholder URLs that follow
# their actual naming convention.
# ---------------------------------------------------------------------------
plans_data = [
  # ── SINGLE SECTION ────────────────────────────────────────────────────────
  {
    name: 'The Amherst',
    model_code: 'CH-AMH-1460',
    series: 'Horizon',
    factory: factories[:indiana],
    beds: 3, baths: 2.0, sqft: 1_460,
    width_feet: 28, length_feet: 52,
    base_price_low: 82_000,  base_price_high: 95_000,
    suggested_retail_low: 99_000,  suggested_retail_high: 118_000,
    specifications: {
      home_type: 'Single Section', construction_type: 'HUD',
      exterior_siding: 'Vinyl', roof_pitch: '5/12',
      ceiling_height: '8 ft', foundation: 'Permanent or Pier'
    },
    images: [
      'https://www.championhomes.com/wp-content/uploads/amherst-front-768x432.jpg',
    ]
  },
  {
    name: 'The Bayfield',
    model_code: 'CH-BAY-1680',
    series: 'Horizon',
    factory: factories[:indiana],
    beds: 3, baths: 2.0, sqft: 1_680,
    width_feet: 28, length_feet: 60,
    base_price_low: 90_000, base_price_high: 105_000,
    suggested_retail_low: 108_000, suggested_retail_high: 129_000,
    specifications: {
      home_type: 'Single Section', construction_type: 'HUD',
      exterior_siding: 'Vinyl', roof_pitch: '5/12',
      ceiling_height: '9 ft', foundation: 'Permanent or Pier'
    },
    images: [
      'https://www.championhomes.com/wp-content/uploads/bayfield-front-768x432.jpg',
    ]
  },
  {
    name: 'The Crestline 16',
    model_code: 'CH-CL16-1040',
    series: 'Value',
    factory: factories[:indiana],
    beds: 3, baths: 2.0, sqft: 1_040,
    width_feet: 16, length_feet: 65,
    base_price_low: 62_000, base_price_high: 72_000,
    suggested_retail_low: 74_000, suggested_retail_high: 88_000,
    specifications: {
      home_type: 'Single Section', construction_type: 'HUD',
      exterior_siding: 'Vinyl', roof_pitch: '4/12',
      ceiling_height: '8 ft', foundation: 'Pier'
    },
    images: []
  },
  {
    name: 'The Westport',
    model_code: 'CH-WPT-1456',
    series: 'Horizon',
    factory: factories[:texas],
    beds: 3, baths: 2.0, sqft: 1_456,
    width_feet: 28, length_feet: 52,
    base_price_low: 84_000, base_price_high: 97_000,
    suggested_retail_low: 101_000, suggested_retail_high: 120_000,
    specifications: {
      home_type: 'Single Section', construction_type: 'HUD',
      exterior_siding: 'Vinyl', roof_pitch: '5/12',
      ceiling_height: '9 ft', foundation: 'Permanent or Pier'
    },
    images: []
  },
  {
    name: 'The Ridgecrest',
    model_code: 'CH-RDG-1764',
    series: 'Horizon',
    factory: factories[:indiana],
    beds: 4, baths: 2.0, sqft: 1_764,
    width_feet: 28, length_feet: 63,
    base_price_low: 97_000, base_price_high: 113_000,
    suggested_retail_low: 117_000, suggested_retail_high: 139_000,
    specifications: {
      home_type: 'Single Section', construction_type: 'HUD',
      exterior_siding: 'Vinyl', roof_pitch: '5/12',
      ceiling_height: '9 ft', foundation: 'Permanent or Pier'
    },
    images: []
  },

  # ── DOUBLE SECTION ─────────────────────────────────────────────────────────
  {
    name: 'The Fairfield',
    model_code: 'CH-FF-2400D',
    series: 'Advantage',
    factory: factories[:indiana],
    beds: 3, baths: 2.0, sqft: 2_400,
    width_feet: 48, length_feet: 50,
    base_price_low: 145_000, base_price_high: 165_000,
    suggested_retail_low: 175_000, suggested_retail_high: 205_000,
    specifications: {
      home_type: 'Double Section', construction_type: 'HUD',
      exterior_siding: 'Vinyl', roof_pitch: '6/12',
      ceiling_height: '9 ft', foundation: 'Permanent'
    },
    images: [
      'https://www.championhomes.com/wp-content/uploads/fairfield-front-768x432.jpg',
    ]
  },
  {
    name: 'The Grandview',
    model_code: 'CH-GV-2800D',
    series: 'Advantage',
    factory: factories[:pennsylvania],
    beds: 4, baths: 2.0, sqft: 2_800,
    width_feet: 56, length_feet: 50,
    base_price_low: 165_000, base_price_high: 190_000,
    suggested_retail_low: 200_000, suggested_retail_high: 235_000,
    specifications: {
      home_type: 'Double Section', construction_type: 'HUD',
      exterior_siding: 'Vinyl', roof_pitch: '6/12',
      ceiling_height: '9 ft', foundation: 'Permanent'
    },
    images: []
  },
  {
    name: 'The Lakewood',
    model_code: 'CH-LKW-3200D',
    series: 'Premier',
    factory: factories[:indiana],
    beds: 4, baths: 3.0, sqft: 3_200,
    width_feet: 60, length_feet: 53,
    base_price_low: 195_000, base_price_high: 228_000,
    suggested_retail_low: 235_000, suggested_retail_high: 278_000,
    specifications: {
      home_type: 'Double Section', construction_type: 'HUD',
      exterior_siding: 'Vinyl or Lap', roof_pitch: '6/12',
      ceiling_height: '9 ft Cathedral Option', foundation: 'Permanent'
    },
    images: []
  },

  # ── PARK MODELS ────────────────────────────────────────────────────────────
  {
    name: 'The Hawthorn Park',
    model_code: 'CH-HAW-400PM',
    series: 'Park Model',
    factory: factories[:indiana],
    beds: 1, baths: 1.0, sqft: 400,
    width_feet: 12, length_feet: 38,
    base_price_low: 42_000, base_price_high: 54_000,
    suggested_retail_low: 52_000, suggested_retail_high: 68_000,
    specifications: {
      home_type: 'Park Model', construction_type: 'ANSI A119.5',
      exterior_siding: 'Vinyl', roof_pitch: '4/12',
      ceiling_height: '7.5 ft', foundation: 'Pier or Wheels'
    },
    images: []
  },
  {
    name: 'The Evergreen Park',
    model_code: 'CH-EVG-500PM',
    series: 'Park Model',
    factory: factories[:indiana],
    beds: 1, baths: 1.0, sqft: 500,
    width_feet: 14, length_feet: 38,
    base_price_low: 54_000, base_price_high: 68_000,
    suggested_retail_low: 66_000, suggested_retail_high: 84_000,
    specifications: {
      home_type: 'Park Model', construction_type: 'ANSI A119.5',
      exterior_siding: 'Vinyl', roof_pitch: '4/12',
      ceiling_height: '7.5 ft', foundation: 'Pier or Wheels'
    },
    images: []
  },
]

# ---------------------------------------------------------------------------
# 4. Standard Option Categories + Options
# These apply to all floor plans. Champion's actual option book mirrors this.
# ---------------------------------------------------------------------------
STANDARD_OPTION_CATEGORIES = [
  {
    name: 'Exterior',
    description: 'Siding, trim, shutters, and color packages',
    is_required: false,
    allow_multiple_selections: false,
    display_order: 1,
    options: [
      { name: 'Standard Vinyl Package', description: 'Standard vinyl siding in white or almond', price_low: 0,      price_high: 0,      is_default: true,  order: 1 },
      { name: 'Premium Vinyl Package',  description: 'Designer color vinyl siding, 6 colors',     price_low: 1_500,  price_high: 2_000,  is_default: false, order: 2 },
      { name: 'Fiber Cement Siding',    description: 'James Hardie® lap siding',                  price_low: 3_500,  price_high: 5_000,  is_default: false, order: 3 },
      { name: 'Shake-Style Accents',    description: 'Decorative shake on gable ends',             price_low: 800,    price_high: 1_200,  is_default: false, order: 4 },
    ]
  },
  {
    name: 'Roofing',
    description: 'Roof pitch, material, and color options',
    is_required: false,
    allow_multiple_selections: false,
    display_order: 2,
    options: [
      { name: 'Standard Shingles (30yr)', description: '30-year architectural shingles, standard colors', price_low: 0,     price_high: 0,     is_default: true,  order: 1 },
      { name: 'Premium Shingles (50yr)', description: '50-year architectural shingles, designer colors', price_low: 1_200, price_high: 1_800, is_default: false, order: 2 },
      { name: 'Upgraded Roof Pitch 6/12', description: 'Upgrade from 4/12 to 6/12 pitch (if applicable)', price_low: 2_000, price_high: 3_000, is_default: false, order: 3 },
    ]
  },
  {
    name: 'Kitchen',
    description: 'Cabinetry, countertops, and appliances',
    is_required: false,
    allow_multiple_selections: true,
    display_order: 3,
    options: [
      { name: 'Standard Cabinetry',        description: 'Thermofoil cabinet doors, standard colors',     price_low: 0,     price_high: 0,     is_default: true,  order: 1 },
      { name: 'Upgraded Wood Cabinetry',   description: 'Shaker-style wood doors with soft close',       price_low: 2_500, price_high: 3_500, is_default: false, order: 2 },
      { name: 'Laminate Countertops',      description: 'Standard laminate countertops',                 price_low: 0,     price_high: 0,     is_default: true,  order: 3 },
      { name: 'Quartz Countertops',        description: 'Quartz countertops throughout kitchen',         price_low: 3_200, price_high: 4_800, is_default: false, order: 4 },
      { name: 'Island w/ Seating',         description: 'Kitchen island with 2-seat breakfast bar',      price_low: 1_800, price_high: 2_500, is_default: false, order: 5 },
      { name: 'Stainless Steel Appliances',description: 'Stainless range, dishwasher, microhood',        price_low: 1_200, price_high: 1_800, is_default: false, order: 6 },
    ]
  },
  {
    name: 'Flooring',
    description: 'Floor covering throughout the home',
    is_required: false,
    allow_multiple_selections: false,
    display_order: 4,
    options: [
      { name: 'Carpet & Vinyl Package',  description: 'Carpet in bedrooms, vinyl in main areas',       price_low: 0,     price_high: 0,     is_default: true,  order: 1 },
      { name: 'Luxury Vinyl Plank (LVP)',description: 'LVP throughout main areas, carpet bedrooms',    price_low: 2_800, price_high: 4_000, is_default: false, order: 2 },
      { name: 'All LVP (No Carpet)',     description: 'Luxury vinyl plank in all rooms',               price_low: 4_500, price_high: 6_000, is_default: false, order: 3 },
      { name: 'Engineered Hardwood',     description: 'Engineered hardwood in living & dining areas',  price_low: 5_500, price_high: 8_000, is_default: false, order: 4 },
    ]
  },
  {
    name: 'Primary Bath',
    description: 'Master bathroom upgrades',
    is_required: false,
    allow_multiple_selections: true,
    display_order: 5,
    options: [
      { name: 'Standard Tub/Shower Combo', description: 'Standard fiberglass tub/shower',                 price_low: 0,     price_high: 0,     is_default: true,  order: 1 },
      { name: 'Garden Soaking Tub',        description: 'Freestanding garden tub in primary bath',        price_low: 1_400, price_high: 2_000, is_default: false, order: 2 },
      { name: 'Walk-In Shower',            description: '4x4 walk-in shower with tile surround',          price_low: 2_200, price_high: 3_200, is_default: false, order: 3 },
      { name: 'Double Vanity Upgrade',     description: 'Double-sink vanity with upgraded faucets',       price_low: 900,   price_high: 1_400, is_default: false, order: 4 },
    ]
  },
  {
    name: 'Energy Efficiency',
    description: 'Insulation and energy-saving upgrades',
    is_required: false,
    allow_multiple_selections: true,
    display_order: 6,
    options: [
      { name: 'Standard Insulation (R-11/R-19)', description: 'Standard wall and ceiling insulation',     price_low: 0,     price_high: 0,     is_default: true,  order: 1 },
      { name: 'Enhanced Insulation Package',     description: 'R-21 walls, R-38 ceiling',                price_low: 1_800, price_high: 2_500, is_default: false, order: 2 },
      { name: 'Low-E Double Pane Windows',       description: 'Upgrade to Low-E double pane windows',    price_low: 1_500, price_high: 2_200, is_default: false, order: 3 },
      { name: 'Energy Star Appliances',          description: 'Energy Star rated appliances package',     price_low: 800,   price_high: 1_200, is_default: false, order: 4 },
    ]
  },
  {
    name: 'Heating & Cooling',
    description: 'HVAC system options',
    is_required: false,
    allow_multiple_selections: false,
    display_order: 7,
    options: [
      { name: 'Forced Air Furnace',          description: 'Standard forced air gas/electric furnace',      price_low: 0,     price_high: 0,     is_default: true,  order: 1 },
      { name: 'Central Air Conditioning',    description: 'Add central A/C to forced air system',          price_low: 2_800, price_high: 3_800, is_default: false, order: 2 },
      { name: 'Heat Pump System',            description: 'Electric heat pump (heat & cool)',               price_low: 3_500, price_high: 5_000, is_default: false, order: 3 },
    ]
  },
  {
    name: 'Exterior Additions',
    description: 'Deck, porch, and exterior add-ons',
    is_required: false,
    allow_multiple_selections: true,
    display_order: 8,
    options: [
      { name: 'No Additions',            description: 'Home only, no exterior additions',              price_low: 0,     price_high: 0,     is_default: true,  order: 1 },
      { name: 'Front Entry Steps',       description: 'Prefab entry steps and landing',                price_low: 600,   price_high: 900,   is_default: false, order: 2 },
      { name: '10x12 Deck',             description: 'Pressure-treated pine 10x12 deck at rear',      price_low: 2_800, price_high: 4_200, is_default: false, order: 3 },
      { name: 'Covered Front Porch',     description: "12x8 covered front porch with railing",        price_low: 4_500, price_high: 6_500, is_default: false, order: 4 },
    ]
  },
]

# ---------------------------------------------------------------------------
# 5. Create / Update floor plans and attach options
# ---------------------------------------------------------------------------
created = 0
updated = 0

plans_data.each do |plan|
  floor_plan = FloorPlan.find_or_initialize_by(
    manufacturer: manufacturer,
    model_code:   plan[:model_code]
  )

  is_new = floor_plan.new_record?

  floor_plan.assign_attributes(
    name:                  plan[:name],
    series:                plan[:series],
    factory:               plan[:factory],
    beds:                  plan[:beds],
    baths:                 plan[:baths],
    sqft:                  plan[:sqft],
    width_feet:            plan[:width_feet],
    length_feet:           plan[:length_feet],
    base_price_low:        plan[:base_price_low],
    base_price_high:       plan[:base_price_high],
    suggested_retail_low:  plan[:suggested_retail_low],
    suggested_retail_high: plan[:suggested_retail_high],
    specifications:        plan[:specifications],
    images_array:          plan[:images],
    is_active:             true
  )

  floor_plan.save!
  is_new ? (created += 1) : (updated += 1)

  # Add standard option categories only if the floor plan has none yet
  if floor_plan.option_categories.none?
    STANDARD_OPTION_CATEGORIES.each do |cat_data|
      category = floor_plan.option_categories.create!(
        name:                     cat_data[:name],
        description:              cat_data[:description],
        is_required:              cat_data[:is_required],
        allow_multiple_selections: cat_data[:allow_multiple_selections],
        display_order:            cat_data[:display_order]
      )

      cat_data[:options].each do |opt|
        category.floor_plan_options.create!(
          name:             opt[:name],
          description:      opt[:description],
          price_impact_low:  opt[:price_low],
          price_impact_high: opt[:price_high],
          is_default:        opt[:is_default],
          display_order:     opt[:order]
        )
      end
    end
    puts "[Seed]   → Added #{STANDARD_OPTION_CATEGORIES.size} option categories"
  else
    puts "[Seed]   → Options already exist, skipping"
  end

  puts "[Seed] #{is_new ? 'CREATED' : 'UPDATED'}: #{floor_plan.name} (#{floor_plan.model_code})"
end

puts ""
puts "[Seed] ✅ Done! Created: #{created}, Updated: #{updated}"
puts "[Seed]    Total floor plans: #{FloorPlan.where(manufacturer: manufacturer).count}"
puts "[Seed]    Total option categories: #{OptionCategory.joins(:floor_plan).where(floor_plans: { manufacturer: manufacturer }).count}"
puts "[Seed]    Total options: #{FloorPlanOption.joins(option_category: :floor_plan).where(floor_plans: { manufacturer: manufacturer }).count}"
