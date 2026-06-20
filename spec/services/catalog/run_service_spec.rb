# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/fake_catalog_adapter')

RSpec.describe Catalog::RunService do
  let(:source) { create(:catalog_source, extraction_threshold: 0.80) }

  def run_with(homes)
    adapter = FakeCatalogAdapter.new(homes)
    allow(source).to receive(:adapter).and_return(adapter)
    described_class.new(source, trigger: 'manual').call
  end

  describe 'healthy run' do
    it 'records a successful, non-degraded run with full extraction rates' do
      homes = %w[101 102 103].map { |k| FakeCatalogAdapter.home(k) }
      run = run_with(homes)

      expect(run.status).to eq('success')
      expect(run.degraded).to be(false)
      expect(run.homes_parsed_ok).to eq(3)
      expect(run.field_extraction_rates['square_feet']).to eq(1.0)
      expect(source.reload.last_run_status).to eq('success')
    end
  end

  describe 'degraded run' do
    it 'flags degraded when a field drops below threshold and alerts' do
      homes = [
        FakeCatalogAdapter.home('1'),
        FakeCatalogAdapter.home('2', square_feet: nil),
        FakeCatalogAdapter.home('3', square_feet: nil)
      ]
      expect(Catalog::DegradationAlerter).to receive(:call).with(hash_including(source: source))

      run = run_with(homes)

      expect(run.degraded).to be(true)
      expect(run.status).to eq('partial')
      expect(run.field_extraction_rates['square_feet']).to be < 0.80
    end
  end

  describe 'no adapter' do
    it 'fails the run when adapter_type has no adapter' do
      allow(source).to receive(:adapter).and_return(nil)
      allow(Catalog::DegradationAlerter).to receive(:call)

      run = described_class.new(source).call
      expect(run.status).to eq('failed')
    end
  end

  describe 'ingestion into subscribers' do
    let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

    it 'upserts homes company-wide (nil location) when no locations selected' do
      create(:dealer_catalog_subscription, company: company, catalog_source: source, enabled: true, location_ids: [])
      homes = %w[201 202].map { |k| FakeCatalogAdapter.home(k) }

      run = run_with(homes)

      expect(run.added_count).to eq(2)
      vehicles = company.vehicles.where(catalog_source_id: source.id)
      expect(vehicles.count).to eq(2)
      expect(vehicles.pluck(:location_id).uniq).to eq([nil])
    end

    it 'creates one copy per selected location' do
      loc_a = company.locations.create!(name: 'A', timezone: 'UTC')
      loc_b = company.locations.create!(name: 'B', timezone: 'UTC')
      create(:dealer_catalog_subscription, company: company, catalog_source: source,
                                           enabled: true, location_ids: [loc_a.id, loc_b.id])
      homes = %w[201 202].map { |k| FakeCatalogAdapter.home(k) }

      run = run_with(homes)

      # 2 homes × 2 locations = 4 copies; 2 per location.
      expect(company.vehicles.where(catalog_source_id: source.id).count).to eq(4)
      expect(company.vehicles.where(catalog_source_id: source.id, location_id: loc_a.id).count).to eq(2)
      expect(company.vehicles.where(catalog_source_id: source.id, location_id: loc_b.id).count).to eq(2)
      expect(run.added_count).to eq(4)
    end

    it 'inactivates copies at a location the dealer deselected' do
      loc_a = company.locations.create!(name: 'A', timezone: 'UTC')
      loc_b = company.locations.create!(name: 'B', timezone: 'UTC')
      sub = create(:dealer_catalog_subscription, company: company, catalog_source: source,
                                                 enabled: true, location_ids: [loc_a.id, loc_b.id])
      homes = [FakeCatalogAdapter.home('201')]
      run_with(homes)
      expect(company.vehicles.where(catalog_source_id: source.id, is_deleted: false).count).to eq(2)

      # Dealer drops location B → only A's copy should remain active.
      sub.update!(location_ids: [loc_a.id])
      run_with(homes)
      active = company.vehicles.where(catalog_source_id: source.id, is_deleted: false)
      expect(active.pluck(:location_id)).to eq([loc_a.id])
    end
  end
end
