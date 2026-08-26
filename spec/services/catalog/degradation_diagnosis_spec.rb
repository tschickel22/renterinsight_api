# frozen_string_literal: true

require 'rails_helper'

# The alert stated the drop and stopped, which left the same investigation to be
# done by hand every time: open the failing pages, open a page from a source that
# still works, and decide whether the field is missing from the site or missing
# from our parsing. That comparison is mechanical and the data for it is stored.
RSpec.describe Catalog::DegradationDiagnosis do
  def source(name:, adapter: 'tru_model_line', threshold: 0.7)
    CatalogSource.create!(name: "#{name}-#{SecureRandom.hex(3)}", adapter_type: adapter,
                          base_url: "https://example.test/#{SecureRandom.hex(3)}",
                          enabled: true, extraction_threshold: threshold)
  end

  def run_for(src, rates, at: 1.hour.ago, degraded: true)
    ScrapeRun.create!(catalog_source_id: src.id, status: 'partial', degraded: degraded,
                      started_at: at, finished_at: at, field_extraction_rates: rates)
  end

  # Run 126 exactly: Tru Mini lost images entirely while Tru Homes, same adapter
  # and same template, was still at 92%. An extractor that works on twelve pages
  # and not on two is not broken; those two pages are.
  describe 'when a sibling source still extracts the field' do
    it 'says there is nothing to fix' do
      mini = source(name: 'Tru Mini')
      homes = source(name: 'Tru Homes')
      run_for(homes, { 'images' => 0.9231 }, degraded: false)
      run = run_for(mini, { 'images' => 0.0 })

      result = described_class.call(source: mini, run: run, threshold: 0.7)

      expect(result).to be_upstream
      expect(result.summary).to match(/nothing to fix/i)
      expect(result.detail).to include('images still extracts fine')
    end

    it 'names the sibling and its rate, so the claim can be checked' do
      mini = source(name: 'Tru Mini')
      homes = source(name: 'Tru Homes')
      run_for(homes, { 'images' => 0.9231 }, degraded: false)
      run = run_for(mini, { 'images' => 0.0 })

      expect(described_class.call(source: mini, run: run, threshold: 0.7).detail)
        .to match(/Tru Homes-\w+ 92%/)
    end
  end

  # The opposite reading matters as much: when every source on an adapter loses
  # the same field at once, the site changed under us.
  describe 'when every source on the adapter lost it' do
    it 'says it is worth looking at' do
      mini = source(name: 'Tru Mini')
      homes = source(name: 'Tru Homes')
      run_for(homes, { 'images' => 0.0 })
      run = run_for(mini, { 'images' => 0.0 })

      result = described_class.call(source: mini, run: run, threshold: 0.7)

      expect(result).not_to be_upstream
      expect(result.verdict).to eq(:ours)
    end

    it 'does not call it upstream when there is no sibling to compare against' do
      only = source(name: 'Lonely')
      run = run_for(only, { 'images' => 0.0 })

      expect(described_class.call(source: only, run: run, threshold: 0.7)).not_to be_upstream
    end

    # A sibling that has not run in a month says nothing about today.
    it 'ignores a sibling whose last run is stale' do
      mini = source(name: 'Tru Mini')
      homes = source(name: 'Tru Homes')
      run_for(homes, { 'images' => 1.0 }, at: 40.days.ago, degraded: false)
      run = run_for(mini, { 'images' => 0.0 })

      expect(described_class.call(source: mini, run: run, threshold: 0.7)).not_to be_upstream
    end

    it 'ignores a sibling from a different adapter' do
      mini = source(name: 'Tru Mini')
      other = source(name: 'Clayton', adapter: 'clayton_epic_region')
      run_for(other, { 'images' => 1.0 }, degraded: false)
      run = run_for(mini, { 'images' => 0.0 })

      expect(described_class.call(source: mini, run: run, threshold: 0.7)).not_to be_upstream
    end
  end

  describe 'when only some of the degraded fields are healthy elsewhere' do
    it 'says so rather than picking a side' do
      mini = source(name: 'Tru Mini')
      homes = source(name: 'Tru Homes')
      run_for(homes, { 'images' => 1.0, 'square_feet' => 0.0 }, degraded: false)
      run = run_for(mini, { 'images' => 0.0, 'square_feet' => 0.0 })

      result = described_class.call(source: mini, run: run, threshold: 0.7)

      expect(result.verdict).to eq(:mixed)
      expect(result.detail).to include('images')
      expect(result.detail).to include('square_feet')
    end
  end
end
