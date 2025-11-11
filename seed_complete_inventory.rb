#!/usr/bin/env ruby
require_relative 'config/environment'

puts "\n=== ADDING COMPLETE RV & MH INVENTORY FOR BROCHURES ==="

company = Company.find(1)
puts "Company: #{company.name}"

# Sample images - using placeholder service
def get_rv_images
  [
    "https://images.unsplash.com/photo-1527786356703-4b100091cd2c?w=1200&h=800&fit=crop",
    "https://images.unsplash.com/photo-1464219789935-c2d9d9aba644?w=1200&h=800&fit=crop",
    "https://images.unsplash.com/photo-1523987355523-c7b5b0dd90a7?w=1200&h=800&fit=crop",
    "https://images.unsplash.com/photo-1550355191-aa8a80b41353?w=1200&h=800&fit=crop",
    "https://images.unsplash.com/photo-1469854523086-cc02fe5d8800?w=1200&h=800&fit=crop"
  ]
end

def get_mh_images
  [
    "https://images.unsplash.com/photo-1564013799919-ab600027ffc6?w=1200&h=800&fit=crop",
    "https://images.unsplash.com/photo-1493809842364-78817add7ffb?w=1200&h=800&fit=crop",
    "https://images.unsplash.com/photo-1502005229762-cf1b2da7c5d6?w=1200&h=800&fit=crop",
    "https://images.unsplash.com/photo-1560448204-e02f11c3d0e2?w=1200&h=800&fit=crop",
    "https://images.unsplash.com/photo-1512917774080-9991f1c4c750?w=1200&h=800&fit=crop"
  ]
end

# RV 1: Luxury Class A Motorhome
rv1 = company.vehicles.create!(
  listing_type: 'rv',
  status: 'available',
  inventory_id: "RV-2026-001",
  year: 2026,
  make: "Renegade",
  model: "XL 45DBM",
  trim: "Super C Diesel",
  vin: "5FNYF18516B123456",
  sale_price: 595000.00,
  description: "Experience ultimate luxury in this magnificent Super C motorhome. The XL 45DBM features a powerful Detroit DD16 diesel engine with 600HP and 1,850 ft-lb torque. With a spacious interior measuring 44'11\", this coach is perfect for full-time living or extended travel. Premium features include multiple slide-outs, residential appliances, king-size bed, full-size washer/dryer, and entertainment systems throughout. The exterior boasts full-body paint, automatic leveling jacks, and ample storage. Towing capacity of 30,000 lbs means you can bring your toys along. This is not just an RV - it's a home on wheels with no compromises.",
  sleeps: 6,
  length: 45,
  location_city: "Denver",
  location_state: "CO",
  images: get_rv_images,
  features: [
    "Detroit DD16 Diesel Engine - 600HP",
    "1,850 ft-lb Torque",
    "30,000 lb Towing Capacity",
    "King-Size Residential Bed",
    "Full-Size Washer & Dryer",
    "Multiple Slide-Outs",
    "Bose Soundbar Home Theater",
    "Residential Refrigerator",
    "Automatic Leveling System",
    "Solar Panel System",
    "Heated & Enclosed Underbelly",
    "Full-Body Paint",
    "Hydraulic Disc Brakes",
    "Air Ride Suspension",
    "Motion-Activated Lighting"
  ]
)
puts "✅ Created RV: #{rv1.display_name}"

# RV 2: Travel Trailer
rv2 = company.vehicles.create!(
  listing_type: 'rv',
  status: 'available',
  inventory_id: "RV-2025-002",
  year: 2025,
  make: "Grand Design",
  model: "Reflection 312BHTS",
  trim: "Fifth Wheel",
  vin: "4YDF312BR3HF45678",
  sale_price: 78500.00,
  description: "This Grand Design Reflection fifth wheel is the perfect blend of luxury and functionality. With triple slide-outs, the interior feels incredibly spacious and welcoming. The master suite features a king bed and private bathroom, while the bunkhouse provides comfortable sleeping for kids or guests. High-end finishes include solid surface countertops, hardwood cabinet doors, and upgraded upholstery. The outdoor kitchen and electric awning with LED lighting make outdoor living a breeze. Built with Grand Design's legendary quality and backed by excellent customer service.",
  sleeps: 8,
  length: 36,
  location_city: "Denver",
  location_state: "CO",
  images: get_rv_images.shuffle,
  features: [
    "Triple Slide-Outs",
    "King-Size Master Bed",
    "Private Master Bathroom",
    "Bunkhouse with 4 Bunks",
    "Outdoor Kitchen",
    "Electric Awning with LED",
    "Solid Surface Countertops",
    "Residential Furniture",
    "Fireplace",
    "12V & USB Outlets",
    "Solar Prep",
    "Heated & Enclosed Tanks",
    "Power Stabilizer Jacks",
    "15K BTU A/C Units (2)",
    "Smart TV with DVD Player"
  ]
)
puts "✅ Created RV: #{rv2.display_name}"

# RV 3: Class C Motorhome
rv3 = company.vehicles.create!(
  listing_type: 'rv',
  status: 'available',
  inventory_id: "RV-2025-003",
  year: 2025,
  make: "Thor Motor Coach",
  model: "Four Winds 28Z",
  trim: "Class C Gas",
  vin: "1FD7W3GT7MEE12345",
  sale_price: 145900.00,
  description: "Perfect for families or couples, this Four Winds Class C offers exceptional value and quality. The Ford E-450 chassis provides reliable power and comfortable driving. Inside, you'll find a well-designed floor plan with a full-wall slide-out that dramatically expands the living space. The kitchen comes equipped with a 3-burner range, microwave, and large refrigerator. The rear bedroom features a queen bed and generous storage. The cab-over bunk adds extra sleeping space. With its compact 28-foot length, this motorhome is easy to drive and park while still offering all the amenities of home.",
  sleeps: 6,
  length: 28,
  location_city: "Aurora",
  location_state: "CO",
  images: get_rv_images.rotate(2),
  features: [
    "Ford E-450 Chassis",
    "Full-Wall Slide-Out",
    "Cab-Over Bunk",
    "Queen Rear Bedroom",
    "Booth Dinette",
    "Overhead Cabinets",
    "3-Burner Range & Oven",
    "Microwave",
    "6 Cu Ft Refrigerator",
    "Ducted A/C",
    "Exterior Shower",
    "Backup Camera",
    "Power Awning",
    "LED Lighting",
    "USB Charging Ports"
  ]
)
puts "✅ Created RV: #{rv3.display_name}"

# MH 1: Modern Double Wide
mh1 = company.vehicles.create!(
  listing_type: 'manufactured_home',
  status: 'available',
  inventory_id: "MH-2025-001",
  year: 2025,
  make: "Champion Homes",
  model: "Prairie Dune 8978",
  serial_number: "CHP250114567890",
  sale_price: 189900.00,
  description: "Welcome to modern manufactured home living! This stunning Champion Prairie Dune offers 2,280 square feet of thoughtfully designed living space. The open-concept floor plan features vaulted ceilings, luxury vinyl plank flooring, and abundant natural light. The gourmet kitchen boasts stainless steel appliances, granite countertops, and a large island perfect for entertaining. The master suite is a true retreat with a spa-like bathroom featuring dual vanities, soaking tub, and separate shower. Energy-efficient construction includes high-grade insulation, dual-pane windows, and an efficient HVAC system. This is quality craftsmanship you can see and feel.",
  bedrooms: 4,
  bathrooms: 2,
  square_feet: 2280,
  location_city: "Thornton",
  location_state: "CO",
  images: get_mh_images,
  features: [
    "2,280 Square Feet",
    "4 Bedrooms, 2 Bathrooms",
    "Open Concept Floor Plan",
    "Vaulted Ceilings",
    "Luxury Vinyl Plank Flooring",
    "Granite Countertops",
    "Stainless Steel Appliances",
    "Kitchen Island with Seating",
    "Master Suite with Walk-In Closet",
    "Dual Vanity Master Bath",
    "Garden Tub & Separate Shower",
    "Energy Star Certified",
    "Dual-Pane Low-E Windows",
    "Central Heat & Air",
    "Covered Front Porch"
  ]
)
puts "✅ Created MH: #{mh1.display_name}"

# MH 2: Single Wide Starter Home
mh2 = company.vehicles.create!(
  listing_type: 'manufactured_home',
  status: 'available',
  inventory_id: "MH-2024-002",
  year: 2024,
  make: "Clayton Homes",
  model: "The Edge Elite 2860",
  serial_number: "CLT240227891234",
  sale_price: 89500.00,
  description: "This Clayton Edge Elite is the perfect starter home or rental property. Despite its efficient single-wide design, the home feels spacious thanks to the open layout and 8-foot ceilings. The kitchen features modern appliances, ample cabinet space, and a breakfast bar. Both bedrooms are generously sized with large closets. The bathroom includes a tub/shower combo and linen storage. Built to HUD code standards with quality materials throughout. The exterior features durable siding and a shingled roof. Ready for immediate delivery and setup.",
  bedrooms: 2,
  bathrooms: 1,
  square_feet: 960,
  location_city: "Commerce City",
  location_state: "CO",
  images: get_mh_images.shuffle,
  features: [
    "960 Square Feet",
    "2 Bedrooms, 1 Bathroom",
    "8-Foot Ceilings",
    "Open Kitchen/Living Layout",
    "Breakfast Bar",
    "Black Appliances",
    "Vinyl Plank Flooring",
    "Carpet in Bedrooms",
    "Large Closets",
    "Linen Storage",
    "Central Heating",
    "Window A/C Ready",
    "Durable Vinyl Siding",
    "Shingled Roof",
    "Energy Efficient"
  ]
)
puts "✅ Created MH: #{mh2.display_name}"

# MH 3: Premium Triple Wide
mh3 = company.vehicles.create!(
  listing_type: 'manufactured_home',
  status: 'available',
  inventory_id: "MH-2025-003",
  year: 2025,
  make: "Skyline Homes",
  model: "Ranch Elite 3268",
  serial_number: "SKY250345678901",
  sale_price: 245000.00,
  description: "Experience luxury living in this expansive Skyline Ranch Elite triple-wide. With 2,560 square feet and a stunning open floor plan, this home rivals traditional site-built construction. The chef's kitchen features top-of-the-line stainless appliances, quartz countertops, soft-close cabinetry, and a massive island with seating for six. The great room showcases a coffered ceiling, electric fireplace, and walls of windows. The master suite is absolutely breathtaking with a sitting area, huge walk-in closet, and luxurious ensuite with freestanding tub and oversized tile shower. Two additional bedrooms share a Jack-and-Jill bath. Premium features include crown molding, engineered hardwood floors, smart home technology, and designer light fixtures throughout.",
  bedrooms: 3,
  bathrooms: 2,
  square_feet: 2560,
  location_city: "Parker",
  location_state: "CO",
  images: get_mh_images.rotate(2),
  features: [
    "2,560 Square Feet",
    "3 Bedrooms, 2 Bathrooms",
    "Triple-Wide Construction",
    "Coffered Ceilings",
    "Quartz Countertops",
    "Top-Line Stainless Appliances",
    "Massive Kitchen Island",
    "Engineered Hardwood Floors",
    "Crown Molding Throughout",
    "Master Suite with Sitting Area",
    "Freestanding Soaking Tub",
    "Oversized Tile Shower",
    "Jack-and-Jill Bath",
    "Smart Home Ready",
    "Premium Light Fixtures"
  ]
)
puts "✅ Created MH: #{mh3.display_name}"

puts "\n=== SUMMARY ==="
puts "Total RVs created: 3"
puts "Total MH created: 3"
puts "\nAll vehicles have:"
puts "- Complete details in every field"
puts "- 5 high-quality images"
puts "- Comprehensive feature lists"
puts "- Professional descriptions"
puts "\n✅ Ready for brochure generation!"
