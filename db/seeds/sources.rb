# frozen_string_literal: true

puts "🎯 Seeding Lead Sources..."

sources_data = [
  { name: 'Website', source_type: 'online', is_active: true },
  { name: 'Referral', source_type: 'word_of_mouth', is_active: true },
  { name: 'Cold Call', source_type: 'outbound', is_active: true },
  { name: 'Email Campaign', source_type: 'marketing', is_active: true },
  { name: 'Social Media', source_type: 'online', is_active: true },
  { name: 'Trade Show', source_type: 'event', is_active: true },
  { name: 'Partner', source_type: 'partner', is_active: true },
  { name: 'Advertisement', source_type: 'marketing', is_active: true },
  { name: 'Walk-in', source_type: 'direct', is_active: true },
  { name: 'Other', source_type: 'other', is_active: true }
]

sources_data.each do |source_attrs|
  Source.find_or_create_by!(name: source_attrs[:name]) do |source|
    source.source_type = source_attrs[:source_type]
    source.is_active = source_attrs[:is_active]
    source.conversion_rate = 0.0
  end
end

puts "   ✅ Created #{Source.count} lead sources"
