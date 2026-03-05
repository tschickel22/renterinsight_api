# frozen_string_literal: true
# =============================================================================
# Import Matterport Virtual Tours from Topeka Plant
# Run: bin/rails runner "load 'db/seeds/import_virtual_tours.rb'"
# =============================================================================

puts "[Virtual Tours] Starting import..."

# ---------------------------------------------------------------------------
# Patch Manufacturer if needed (same workaround as manifest import)
# ---------------------------------------------------------------------------
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
  puts "[Virtual Tours] Patched Manufacturer for missing columns"
end

# ---------------------------------------------------------------------------
# 1. Manufacturers (create Fortune Homes if needed)
# ---------------------------------------------------------------------------
MFRS = {}

[
  ['Champion Homes', 'CHAMP',   'https://www.championhomes.com'],
  ['Redman Homes',   'REDMAN',  'https://www.redmanhomes.com'],
  ['Dutch Housing',  'DUTCH',   'https://www.dutchhousing.com'],
  ['Fortune Homes',  'FORTUNE', 'https://www.fortunehomes.com'],
].each do |name, code, website|
  m = Manufacturer.find_or_initialize_by(name: name)
  m.assign_attributes(industry_type: 'manufactured_home', active: true, code: code, website: website)
  m.save!
  MFRS[name] = m
end

puts "[Virtual Tours] Manufacturers: #{MFRS.keys.join(', ')}"

# Ensure each manufacturer has a Topeka factory
MFRS.each do |name, mfr|
  Factory.find_or_initialize_by(manufacturer: mfr, code: 'TOPEKA-IN').tap do |f|
    f.assign_attributes(name: "#{name} - Topeka", city: 'Topeka', state: 'IN', zip: '46571', is_active: true)
    f.save!
  end
end

# ---------------------------------------------------------------------------
# 2. Map factory column to manufacturer(s)
# ---------------------------------------------------------------------------
def resolve_brands(factory_col)
  case factory_col.strip
  when /\ADutch Topeka/i          then ['Dutch Housing']
  when /\ARedman Topeka/i         then ['Redman Homes']
  when /\AFortune Topeka/i        then ['Fortune Homes']
  when /\ATopeka RHP/i            then ['Redman Homes']
  when /\AParamount/i             then ['Redman Homes']
  when /\ARedman Homes/i          then ['Redman Homes']
  when /\ARedman,\s*Dutch\s*and\s*Fortune/i, /\ARedman,\s*Dutch,\s*Fortune/i
    ['Redman Homes', 'Dutch Housing', 'Fortune Homes']
  when /\ARedman,\s*Fortune/i
    ['Redman Homes', 'Fortune Homes']
  when /\AChampion\s+Redman/i
    ['Champion Homes', 'Redman Homes']
  when /\ATopeka\s*\(Dutch and Redman\)/i
    ['Dutch Housing', 'Redman Homes']
  when /\AChampion/i              then ['Champion Homes']
  when /\ARedman/i                then ['Redman Homes']
  when /\ADutch/i                 then ['Dutch Housing']
  when /\ATopeka\z/i              then ['Champion Homes']
  else
    puts "[Virtual Tours] WARNING: Unknown factory '#{factory_col}', defaulting to Champion"
    ['Champion Homes']
  end
end

# ---------------------------------------------------------------------------
# 3. Virtual tour data
# ---------------------------------------------------------------------------
TOURS = <<~DATA
  112	Dutch Topeka	Dutch Diamond APEX 2860 236	https://my.matterport.com/show/?m=CYsWKUbRgrk
  112	Dutch Topeka	Dutch Modular DM6811	https://my.matterport.com/show/?m=ZgnBACJNej8
  112	Redman Topeka	Advantage 1680 265	https://my.matterport.com/show/?m=1Fm1RDiuY2F
  112	Redman Topeka	Advantage 2864 233 (APEX)	https://my.matterport.com/show/?m=zy72KMgpfjS
  112	Redman Topeka	New Moon 7205 (Omaha)	https://my.matterport.com/show/?m=AHE29A6k2Rg
  112	Redman Topeka	RNM 3266-01 (The Petosky)	https://my.matterport.com/show/?m=BBrFpQnPxJK
  112	Redman Topeka	New Moon 6034 (The Myrtle)	https://my.matterport.com/show/?m=qZhqhUNyfXc
  112	Redman Topeka	Advantage 2856 201 (Warren)	https://my.matterport.com/show/?m=eNe18DWRpkS
  112	Redman Topeka	2860 237 (Catena)	https://my.matterport.com/show/?m=DXxUf1GS4Ps
  112	Redman Topeka	1680 269	https://my.matterport.com/show/?m=N3hsNtzyCb6
  112	Redman Topeka	Advantage 2872 204	https://my.matterport.com/show/?m=KHAHS3eskrq
  112	Redman Topeka	Advantage 2852 206	https://my.matterport.com/show/?m=wLqaowwafKk
  112	Redman Topeka	Advantage 1670 201	https://my.matterport.com/show/?m=uWXCjapKkkW
  112	Redman Topeka	Advantage 1680 203	https://my.matterport.com/show/?m=cM6irRRdF6s
  112	Redman Topeka	Advantage 2848 202 (Hudson)	https://my.matterport.com/show/?m=KRhs183K224
  112	Redman Topeka	Advantage 2870 201	https://my.matterport.com/show/?m=adidkgK2J8v
  112	Redman Topeka	Advantage 3276 201	https://my.matterport.com/show/?m=WgCWWW2xN4b
  112	Redman Topeka	Advantage 3280-217	https://my.matterport.com/show/?m=KbWEqLHkh2Z
  112	Topeka (Dutch and Redman)	2852 901	https://my.matterport.com/show/?m=5gsHRjVG3Cj
  112	Topeka (Dutch and Redman)	2868 237 (Summit)	https://my.matterport.com/show/?m=5pvBSkYRt54
  112	Topeka (Dutch and Redman)	2460 203 (Brooklyn)	https://my.matterport.com/show/?m=Eh5eEk5CYmf
  112	Topeka (Dutch and Redman)	1680 271	https://my.matterport.com/show/?m=a48kC8LEpk5
  112	Topeka RHP	1680 RHP HI 7616	https://my.matterport.com/show/?m=QLf6PMTxZyA
  112	Redman Topeka	New Moon 60301 (The Fenton)	https://my.matterport.com/show/?m=WMjKA5xDSh8
  112	Redman Topeka	Advantage 2856 201 (Warren)	https://my.matterport.com/show/?m=AJv4vg7Mmxf
  112	Dutch Topeka	Barclay BC6414	https://my.matterport.com/show/?m=8Rcnihr8HiR
  112	Dutch Topeka [Tri Star Custom]	Diamond 1646 MW1	https://my.matterport.com/show/?m=R5daQ8qk5us
  112	Redman Topeka	Advantage 2852 208 (Brighton w/ opt kit 3)	https://my.matterport.com/show/?m=Lxb7tySgC9Q
  112	Topeka	1680 204	https://my.matterport.com/show/?m=9FEqWqvseaq
  112	Topeka	1670 215	https://my.matterport.com/show/?m=bunjHqiPD1L
  112	Dutch Topeka	Diamond 1680 907	https://my.matterport.com/show/?m=jHuLB7bpT2H
  112	Topeka	2864 241 (Leland w/ UK3)	https://my.matterport.com/show/?m=Afa4yYziL8n
  112	Fortune Topeka	Gold Star 2850 201 (Chilton)	https://my.matterport.com/show/?m=YRQihriMtQR
  112	Redman Topeka	Advantage 3272-219	https://my.matterport.com/show/?m=F1tA2zee5FW
  112	Fortune Topeka	Fortune Gold Star 2860 205R	https://my.matterport.com/show/?m=9Hxj52im4cj
  112	Fortune Topeka	Fortune Gold Star 2460 203R	https://my.matterport.com/show/?m=2wjKDyR9Naw
  112	Dutch Topeka	Barclay 6017	https://my.matterport.com/show/?m=uNASDTnthZj
  112	Dutch Topeka	Dutch Modular 5205R	https://my.matterport.com/show/?m=3nZBy4yzVQP
  112	Dutch Topeka	Dutch Modular 6011R	https://my.matterport.com/show/?m=3jJXHK2XXGK
  112	Dutch Topeka	Dutch Modular 6409R	https://my.matterport.com/show/?m=CaXFqUjamVP
  112	Redman, Dutch and Fortune Topeka	1680 275	https://my.matterport.com/show/?m=RuFtSTVuggB
  112	Redman, Dutch and Fortune Topeka	2856 241 (Pontiac)	https://my.matterport.com/show/?m=gj2PcCYwJdJ
  112	Dutch Topeka	2856 907	https://my.matterport.com/show/?m=FnZ7JxNT7Cn
  112	Redman, Fortune Topeka	3264 215 (Shelby)	https://my.matterport.com/show/?m=vrK6FVLfsYe
  112	Topeka	Advantage 1670 202	https://my.matterport.com/show/?m=XifXWce7kkx
  112	Topeka	Advantage 2856 201 (Warren)	https://my.matterport.com/show/?m=rfHyEmTZ53E
  112	Redman Topeka	Advantage 3268 241	https://my.matterport.com/show/?m=kcyV59YeKaq
  112	Dutch Topeka	Diamond 3272 214 (Madison)	https://my.matterport.com/show/?m=GxNBSqLYMdz
  112	Redman Topeka	The Bristow - RM2007	https://my.matterport.com/show/?m=6ERBBdCA7Uw
  112	Redman, Dutch and Fortune Topeka	2860 249 (Easton)	https://my.matterport.com/show/?m=1WbTQxhZkoF
  112	Redman, Dutch and Fortune Topeka	2868 245 (Georgetown)	https://my.matterport.com/show/?m=YPtpvLpSgsf
  112	Redman, Dutch and Fortune Topeka	2868 243 (Fillmore)	https://my.matterport.com/show/?m=4ZXgyJf4TrZ
  112	Redman, Dutch and Fortune Topeka	1680 277	https://my.matterport.com/show/?m=pTvNN2nwKia
  112	Redman Homes	Foundation 1670 907	https://my.matterport.com/show/?m=Wk6HP6XkF7z&brand=0
  112	Redman, Dutch, Fortune	1680 203	https://my.matterport.com/show/?m=7EybqP3vdmY
  112	Redman, Dutch, Fortune	1680 265 (2 bedroom)	https://my.matterport.com/show/?m=KrXZxYG4R8L
  112	Redman, Dutch, Fortune	1680 265 (3 bedroom)	https://my.matterport.com/show/?m=jydTgQvxtSi
  112	Redman, Dutch, Fortune	Advantage 3276 211	https://my.matterport.com/show/?m=boGCdaAqSaJ
  112	Champion 	2872 243 Odyssey	https://my.matterport.com/show/?m=AUzLQJnNkxv
  112	Redman	RA3272-AJR3	https://my.matterport.com/show/?m=xJBsQQkoTeY
  112	Redman	Redman Advantage 2860-251	https://my.matterport.com/show/?m=SwoLeQFnW8Q
  112	Redman	Redman Advantage 3280-AW12	https://my.matterport.com/show/?m=r87CsLB6Zez
  112	Champion	2856-202 Warren	https://my.matterport.com/show/?m=YSHhmjLg532
  112	Champion	Advantage 1670 291F	https://my.matterport.com/show/?m=4PxFEtum7Sr
  112	Dutch Topeka	Campbell	https://my.matterport.com/show/?m=1YGhM7TEYYb
  112	Champion	Winston	https://my.matterport.com/show/?m=DTqXpJJSKtZ
  112	Champion Redman	3264 217 Fenton	https://my.matterport.com/show/?m=25XxjsUTiBF
  112	Champion	Monroe 2844 201	https://my.matterport.com/show/?m=gpczG6C2Ydh
  112	Champion	1466H32082	https://my.matterport.com/show/?m=NASgpGLKV8q
  112	Champion	1676H32090	https://my.matterport.com/show/?m=WL6eDvYYiYb
  112	Champion	1676H32090	https://my.matterport.com/show/?m=hSmJRg9YQjg
  112	Champion Redman	Advantage 3270 AJR3	https://my.matterport.com/show/?m=uFwYdE3vggm
  112	Champion	Big Sky 2868M	https://my.matterport.com/show/?m=TeYQYouFtSk
  112	Champion	2860H32301 Easton	https://my.matterport.com/show/?m=AcAdNkhLpHJ
  112	Champion	1676H32090	https://my.matterport.com/show/?m=JkJGwJcLA1u
  112	Champion	Belvidere	https://my.matterport.com/show/?m=vb9wTWyz2uv
  112	Champion	Aspire 1666H32219	https://my.matterport.com/show/?m=iC9BXV2KULL
  112	Champion	Aspire 1666H32212	https://my.matterport.com/show/?m=rDmKKNEStrM
  112	Redman	Paramount 3260M32182 Fenton	https://my.matterport.com/show/?m=smWSnoh5Xy4
  112	Redman	Paramount 2856S22IN1	https://my.matterport.com/show/?m=2sfLumxEm8K
  112	Champion Redman	3280 217 Red Cedar	https://my.matterport.com/show/?m=ZoBGgduZwx9
  112	Champion	2856 241 Pontiac	https://my.matterport.com/show/?m=DDazBkFhtRV
  112	Redman	3268 217 	https://my.matterport.com/show/?m=JAYdW3biFTL
  112	Champion	Aspire 1672H32184 	https://my.matterport.com/show/?m=ixeh5ADyNhC
  112	Champion	Aspire 1666H32120 	https://my.matterport.com/show/?m=4PkEsrHWz6j
  112	Champion	Aspire 1676H32089 	https://my.matterport.com/show/?m=VuwvcQaBZ6A
  112	Redman	The Pontiac [League of Cities]	https://my.matterport.com/show/?m=QZAgSV1oSAx
  112	Dutch	Little Sky	https://my.matterport.com/show/?m=enonZQJRzPy
  112	Dutch Topeka	Timberlake 3260H	https://my.matterport.com/show/?m=ESDwRWfZeqs
  112	Champion	Oasis	https://my.matterport.com/show/?m=NLyXhxuME74
  112	Paramount	Paramount 1676H32259	https://my.matterport.com/show/?m=AWkbFGPfWuD
  112	Champion	1680 901CR -not on web	https://my.matterport.com/show/?m=fpSsQz2Ks1i
  112	Champion	1660 901CR1 -not on web	https://my.matterport.com/show/?m=tY9NFTLwSWW
  112	Redman	Paramount 3268C32AJR1 [Prairie View]	https://my.matterport.com/show/?m=nR5AmuLk4DP
  112	Redman	Paramount 1668H32259	https://my.matterport.com/show/?m=b6GH5S4K6pM
  112	Redman	Paramount 2864H42177	https://my.matterport.com/show/?m=jPDrm8aP1Y3
  112	Dutch Topeka	Aspire 1676H32107	https://my.matterport.com/show/?m=erFQrkKYFTB
  112	Champion	Prime 1676H32P01-112	https://my.matterport.com/show/?m=uVdbUU2NNUr
DATA

# ---------------------------------------------------------------------------
# 4. Parse and process tours
# ---------------------------------------------------------------------------
created = 0
updated = 0
tour_count = 0

TOURS.strip.each_line do |line|
  parts = line.strip.split("\t")
  next if parts.size < 4

  factory_num, factory_col, model_name, tour_url = parts[0].strip, parts[1].strip, parts[2].strip, parts[3].strip
  brand_names = resolve_brands(factory_col)

  # Clean model name for display and code generation
  display_name = model_name
    .gsub(/\s*-not on web\s*/i, '')
    .gsub(/\s*\[.*?\]\s*/, ' ')       # [League of Cities] → space
    .gsub(/\s*\(.*?\)\s*/, ' ')        # (APEX) → space (keep parenthetical for notes)
    .gsub(/\s+/, ' ')
    .strip

  # Extract parenthetical notes (model nicknames like "Warren", "Hudson")
  nickname = model_name[/\(([^)]+)\)/, 1]

  # Build model_code from the model name
  model_code = model_name
    .gsub(/\s*-not on web\s*/i, '')
    .gsub(/\[.*?\]/, '')
    .gsub(/\(.*?\)/, '')
    .gsub(/[^a-zA-Z0-9\s-]/, '')
    .strip
    .gsub(/\s+/, '-')
    .upcase

  # Build the virtual tour asset entry
  tour_asset = {
    'url'          => tour_url,
    'category'     => 'virtual_tour',
    'content_type' => 'text/html',
    'filename'     => model_name,
    'matterport'   => true,
  }

  brand_names.each do |brand_name|
    manufacturer = MFRS[brand_name]
    factory = Factory.find_by(manufacturer: manufacturer, code: 'TOPEKA-IN')

    # Prefix model_code with VT- to avoid conflicts with manifest-imported plans
    full_code = "VT-#{model_code}"

    floor_plan = FloorPlan.find_or_initialize_by(
      manufacturer: manufacturer,
      model_code: full_code
    )

    is_new = floor_plan.new_record?

    if is_new
      floor_plan.assign_attributes(
        name: display_name,
        series: 'virtual-tours',
        factory: factory,
        images_array: [tour_asset],
        is_active: true
      )
    else
      # Add tour to existing images_array if not already present (by URL)
      existing_urls = (floor_plan.images_array || []).map { |i| i['url'] }
      unless existing_urls.include?(tour_url)
        floor_plan.images_array = (floor_plan.images_array || []) + [tour_asset]
      end
    end

    floor_plan.save!
    is_new ? (created += 1) : (updated += 1)
    tour_count += 1

    status = is_new ? 'CREATED' : 'UPDATED'
    puts "[Virtual Tours] #{status}: #{brand_name} / #{display_name} (#{full_code}) → #{tour_url[0..50]}..."
  end
end

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
puts ""
puts "[Virtual Tours] ============================================"
puts "[Virtual Tours] Done! Created: #{created}, Updated: #{updated}"
puts "[Virtual Tours] Total tour assignments: #{tour_count}"
MFRS.each do |name, mfr|
  vt_count = FloorPlan.where(manufacturer: mfr, series: 'virtual-tours').count
  puts "[Virtual Tours]   #{name}: #{vt_count} floor plans with virtual tours"
end
puts "[Virtual Tours] ============================================"
