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
end
