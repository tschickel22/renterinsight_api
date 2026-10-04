# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TruebuildRenderJob do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Bay Port') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32168', width_ft: 28, length_ft: 56) }

  def row(status:, age:)
    TruebuildRender.create!(catalog_plan_variant: variant, source_url: 'https://s7d9.scene7.com/p', room: 'kitchen', purpose: 'layer',
                            selection: [{ 'surface' => 'Cabinets', 'value' => 'White' }], selection_key: SecureRandom.hex(4),
                            model_key: 'nb2-lite', provider: 'gemini', model: 'lite', prompt: 'p', status: status,
                            usage: { 'job_id' => 'gone' }).tap { |r| r.update_columns(updated_at: age.ago) }
  end

  describe '.orphaned' do
    let(:scope) { TruebuildRender.where(purpose: 'layer') }

    it 'finds a row whose job no longer exists, without waiting out the stale window' do
      lost = row(status: 'queued', age: 3.minutes)
      alive = row(status: 'running', age: 3.minutes)
      fresh = row(status: 'queued', age: 10.seconds)
      row(status: 'done', age: 1.hour)
      allow(described_class).to receive(:live_render_ids).and_return(Set[alive.id])

      expect(described_class.orphaned(scope, stale_after: 15.minutes)).to eq([lost])
      expect(fresh).to be_persisted
    end

    it 'never takes a drawing under way for lost before the stale window, whatever the queue says' do
      drawing = row(status: 'running', age: 3.minutes)
      stuck = row(status: 'running', age: 20.minutes)
      allow(described_class).to receive(:live_render_ids).and_return(Set[])

      expect(described_class.orphaned(scope, stale_after: 15.minutes)).to eq([stuck])
      expect(drawing).to be_persisted
    end

    it "reads the queue's own decoded arguments" do
      allow(ActiveJob::Base).to receive(:queue_adapter).and_return(ActiveJob::QueueAdapters::SolidQueueAdapter.new)
      SolidQueue::Job.create!(queue_name: 'low', class_name: described_class.name,
                              arguments: { 'job_class' => described_class.name, 'arguments' => [4242] })
      expect(described_class.live_render_ids).to include(4242)
    end

    it 'falls back to age when the queue cannot be asked' do
      old = row(status: 'running', age: 20.minutes)
      row(status: 'running', age: 3.minutes)
      allow(described_class).to receive(:live_render_ids).and_return(nil)

      expect(described_class.orphaned(scope, stale_after: 15.minutes)).to eq([old])
    end
  end

  it 'requeues a lost row as queued without its old job id' do
    lost = row(status: 'running', age: 3.minutes)
    expect { described_class.requeue(lost) }.to have_enqueued_job(described_class).with(lost.id)
    expect(lost.reload.status).to eq('queued')
    expect(lost.usage).not_to have_key('job_id')
  end
end
