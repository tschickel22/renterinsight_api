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

  # Two runs on one source double the request rate at the manufacturer, make two
  # archivers download the same images, and race two ingests over rows that have
  # no UNIQUE index. Run Now guarded this; the nightly sweep and the
  # subscription path did not.
  describe 'concurrency guard' do
    it 'skips a run when one is already in flight' do
      create(:scrape_run, catalog_source: source, status: 'running',
                          started_at: 1.minute.ago, finished_at: nil)

      expect(run_with([FakeCatalogAdapter.home('1')])).to be_nil
      expect(source.scrape_runs.count).to eq 1
    end

    # Otherwise a run killed by a deploy blocks the source forever.
    it 'reaps an abandoned run and proceeds' do
      dead = create(:scrape_run, catalog_source: source, status: 'running',
                                 started_at: (ScrapeRun::STALE_AFTER + 5.minutes).ago,
                                 finished_at: nil)

      run = run_with([FakeCatalogAdapter.home('1')])

      expect(dead.reload.status).to eq 'failed'
      expect(run).to be_present
      expect(run.status).to eq 'success'
    end

    it 'runs normally when nothing is in flight' do
      expect(run_with([FakeCatalogAdapter.home('1')])).to be_present
    end
  end

  # Counters only appeared at finalize, so an in-flight run reported zeros for
  # its whole duration and a healthy crawl looked identical to a dead one.
  describe 'progress reporting' do
    it 'records discovered count before parsing finishes' do
      homes = %w[1 2 3].map { |k| FakeCatalogAdapter.home(k) }
      seen  = []

      adapter = FakeCatalogAdapter.new(homes)
      allow(source).to receive(:adapter).and_return(adapter)
      allow(adapter).to receive(:parse).and_wrap_original do |orig, *args|
        seen << source.scrape_runs.last&.reload&.homes_discovered
        orig.call(*args)
      end

      described_class.new(source, trigger: 'manual').call

      expect(seen).to all(eq(3))
    end

    it 'increments parsed count as it goes' do
      homes = %w[1 2 3].map { |k| FakeCatalogAdapter.home(k) }
      seen  = []

      adapter = FakeCatalogAdapter.new(homes)
      allow(source).to receive(:adapter).and_return(adapter)
      allow(adapter).to receive(:fetch).and_wrap_original do |orig, *args|
        seen << source.scrape_runs.last&.reload&.homes_parsed_ok
        orig.call(*args)
      end

      described_class.new(source, trigger: 'manual').call

      expect(seen).to eq [0, 1, 2]
    end
  end

  # The call site is where this broke: RunService did config[...].to_i, turning
  # an unset delay into 0 rather than letting the archiver apply DEFAULT_DELAY.
  # Assert the raw value reaches the archiver so the fix cannot be undone here.
  describe 'image archiving' do
    let(:archiver) { instance_double(Catalog::ImageArchiver, archive: [], result: nil) }

    before do
      allow(archiver).to receive(:result).and_return(
        Catalog::ImageArchiver::Result.new(archived: 0, reused: 0, failed: 0, skipped: 0,
                                           rate_limited: false)
      )
    end

    it 'passes an unset delay through as nil, so the polite default applies' do
      source.update!(config: { 'archive_images' => true })
      expect(Catalog::ImageArchiver).to receive(:new).with(crawl_delay: nil).and_return(archiver)

      run_with([FakeCatalogAdapter.home('1')])
    end

    it 'passes a configured delay through unchanged' do
      source.update!(config: { 'archive_images' => true, 'image_crawl_delay' => 5 })
      expect(Catalog::ImageArchiver).to receive(:new).with(crawl_delay: 5).and_return(archiver)

      run_with([FakeCatalogAdapter.home('1')])
    end

    it 'does not archive at all unless the source opts in' do
      source.update!(config: {})
      expect(Catalog::ImageArchiver).not_to receive(:new)

      run_with([FakeCatalogAdapter.home('1')])
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
