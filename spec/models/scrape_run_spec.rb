# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScrapeRun do
  let(:source) { create(:catalog_source, last_run_status: 'running') }

  def running_run(started_at:, src: source)
    create(:scrape_run, catalog_source: src, status: 'running',
                        started_at: started_at, finished_at: nil)
  end

  # A deploy or restart kills the in-Puma worker mid-crawl, leaving the row and
  # the source's last_run_status claiming "running" forever. Reaping used to
  # live in the admin controller and fire ONLY on Run Now, so until somebody
  # pressed that button every other reader saw a phantom crawl in progress.
  describe '.reap_stale!' do
    it 'fails a run abandoned past STALE_AFTER' do
      run = running_run(started_at: (described_class::STALE_AFTER + 5.minutes).ago)

      expect(described_class.reap_stale!).to eq 1
      expect(run.reload.status).to eq 'failed'
      expect(run.finished_at).to be_present
      expect(run.error_log.first['message']).to match(/worker stopped/i)
    end

    it 'un-sticks the source, so the list stops reporting a crawl' do
      running_run(started_at: (described_class::STALE_AFTER + 5.minutes).ago)

      described_class.reap_stale!

      expect(source.reload.last_run_status).to eq 'failed'
    end

    it 'leaves a genuinely in-flight run alone' do
      run = running_run(started_at: 2.minutes.ago)

      expect(described_class.reap_stale!).to eq 0
      expect(run.reload.status).to eq 'running'
      expect(source.reload.last_run_status).to eq 'running'
    end

    it 'does nothing when there is nothing to reap' do
      expect(described_class.reap_stale!).to eq 0
    end

    it 'never touches a run that already finished' do
      run = create(:scrape_run, catalog_source: source, status: 'success',
                                started_at: 3.hours.ago, finished_at: 2.hours.ago)

      described_class.reap_stale!

      expect(run.reload.status).to eq 'success'
    end

    it 'can be scoped to one source' do
      other = create(:catalog_source, last_run_status: 'running')
      mine  = running_run(started_at: 1.hour.ago)
      theirs = running_run(started_at: 1.hour.ago, src: other)

      described_class.reap_stale!(source.scrape_runs)

      expect(mine.reload.status).to eq 'failed'
      expect(theirs.reload.status).to eq 'running'
    end

    it 'does not demote a source whose latest status is already terminal' do
      source.update!(last_run_status: 'success')
      running_run(started_at: 1.hour.ago)

      described_class.reap_stale!

      expect(source.reload.last_run_status).to eq 'success'
    end
  end

  describe '#actually_running?' do
    it 'is true for a fresh running row' do
      expect(running_run(started_at: 1.minute.ago)).to be_actually_running
    end

    # The status column insists otherwise, which is exactly the trap.
    it 'is false for a row abandoned by a dead worker' do
      expect(running_run(started_at: 2.hours.ago)).not_to be_actually_running
    end

    it 'is false for a finished run' do
      expect(create(:scrape_run, catalog_source: source, status: 'success')).not_to be_actually_running
    end
  end

  describe 'triggers' do
    # A dealer subscribing and the nightly sweep both used to record
    # 'scheduled', so run history could not explain a mid-afternoon crawl.
    it 'accepts subscription as a distinct trigger' do
      expect(build(:scrape_run, catalog_source: source, trigger: 'subscription')).to be_valid
    end

    it 'still rejects an unknown trigger' do
      expect(build(:scrape_run, catalog_source: source, trigger: 'whatever')).not_to be_valid
    end
  end
end
