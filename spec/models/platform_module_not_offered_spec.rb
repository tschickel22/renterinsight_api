# frozen_string_literal: true

require 'rails_helper'

# Lot Map, PDI Checklist and Delivery Tracker are not offered (Tom, 2026-11-17), so no plan includes them.
RSpec.describe PlatformModule do
  it 'leaves Lot Map, PDI Checklist and Delivery Tracker out of every plan template' do
    PlatformModule::PLAN_TEMPLATES.each_key do |tier|
      expect(described_class.template_modules(tier)).not_to include('inventory.lot_map', 'inventory.pdi', 'inventory.delivery'), tier.to_s
    end
  end

  it 'still knows the keys, so old plan rows and the menu resolve' do
    expect(described_class.valid_key?('inventory.lot_map')).to be(true)
    expect(described_class.valid_key?('inventory.pdi')).to be(true)
    expect(described_class.valid_key?('inventory.delivery')).to be(true)
  end
end
