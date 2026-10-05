# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CatalogSource do
  describe 'schedule normalization' do
    it 'coerces legacy and unknown values to the enum' do
      expect(create(:catalog_source, schedule: 'Nightly').schedule).to eq('daily')
      expect(create(:catalog_source, schedule: 'WEEKLY').schedule).to eq('weekly')
      expect(create(:catalog_source, schedule: 'whatever').schedule).to eq('weekly')
      expect(create(:catalog_source, schedule: 'manual').schedule).to eq('manual')
    end
  end

  describe '#due?' do
    let(:source) { create(:catalog_source, enabled: true) }

    it 'daily: due when never run or last run > 20h ago' do
      source.update!(schedule: 'daily', last_run_at: nil)
      expect(source.due?).to be(true)
      source.update!(last_run_at: 21.hours.ago)
      expect(source.due?).to be(true)
      source.update!(last_run_at: 2.hours.ago)
      expect(source.due?).to be(false)
    end

    it 'weekly: due only after ~a week' do
      source.update!(schedule: 'weekly', last_run_at: 3.days.ago)
      expect(source.due?).to be(false)
      source.update!(last_run_at: 7.days.ago)
      expect(source.due?).to be(true)
    end

    it 'manual never auto-runs; disabled is never due' do
      source.update!(schedule: 'manual', last_run_at: nil)
      expect(source.due?).to be(false)
      source.update!(schedule: 'daily', enabled: false, last_run_at: nil)
      expect(source.due?).to be(false)
    end
  end

  # Kabco dropped out of the dealer picker on 2026-10-05: one home of seventy
  # failed a smoke check, the run finished "partial", and the next crawl set the
  # source to "running". Either one hid it.
  describe '#selectable_for_dealers?' do
    let(:source) { create(:catalog_source, enabled: true) }

    def finished(status, degraded: false, at: 1.hour.ago)
      create(:scrape_run, catalog_source: source, status: status, degraded: degraded,
                          started_at: at, finished_at: at, created_at: at)
    end

    it 'is false before any run has finished' do
      expect(source.selectable_for_dealers?).to be(false)
    end

    it 'accepts a partial run that cleared the degradation threshold' do
      finished('partial')
      expect(source.selectable_for_dealers?).to be(true)
    end

    it 'rejects a degraded or failed latest run' do
      finished('partial', degraded: true)
      expect(source.selectable_for_dealers?).to be(false)

      finished('failed', at: 10.minutes.ago)
      expect(source.selectable_for_dealers?).to be(false)
    end

    it 'stays selectable while the next crawl is running or after one was interrupted' do
      finished('success', at: 2.hours.ago)
      finished('interrupted', at: 1.hour.ago)
      create(:scrape_run, catalog_source: source, status: 'running', started_at: Time.current, finished_at: nil)
      source.update_columns(last_run_status: 'running')

      expect(source.selectable_for_dealers?).to be(true)
    end

    it 'is false when the source is disabled' do
      finished('success')
      source.update!(enabled: false)
      expect(source.selectable_for_dealers?).to be(false)
    end
  end
end
