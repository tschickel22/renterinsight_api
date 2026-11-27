# frozen_string_literal: true

require 'rails_helper'

# Every module a dealer can have gets at least one how it works note (E118),
# so help can explain the rules behind any screen, not only the ones someone
# wrote an article for. A new module fails this until it has one.
RSpec.describe 'How it works notes cover every module' do
  NOT_COVERED = %w[inventory.lot_map inventory.pdi inventory.delivery admin.platform].freeze # not offered, or staff only

  let(:notes) { Dir[Rails.root.join('db/guide/how_it_works_*.yml')].flat_map { |f| YAML.safe_load_file(f)['articles'] } }

  it 'has a note for every offered module' do
    covered = notes.flat_map { |n| Array(n['covers_modules']) }
    expect(PlatformModule::MODULES.keys - NOT_COVERED - covered).to eq([])
  end

  it 'only names modules that exist' do
    expect(notes.flat_map { |n| Array(n['covers_modules']) } - PlatformModule::MODULES.keys).to eq([])
  end

  it 'uses unique slugs, no dashes, and never names the not-offered modules' do
    expect(notes.map { |n| n['slug'] }).to eq(notes.map { |n| n['slug'] }.uniq)
    notes.each do |n|
      text = "#{n['title']} #{n['excerpt']} #{n['content']}"
      expect(text).not_to match(/[–—]/), n['slug']
      expect(text).not_to include('DealerTide'), n['slug']
      expect(text).not_to match(/lot map|PDI checklist|delivery tracker/i), n['slug']
    end
  end
end
