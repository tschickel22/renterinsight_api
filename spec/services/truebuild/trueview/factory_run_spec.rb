# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::FactoryRun do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:topeka) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:decatur) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: topeka, name: 'Topeka 2026', status: 'published') }
  let(:exterior) { CatalogOptionGroup.create!(manufacturer: mfr, factory: topeka, key: 'exterior', name: 'Exterior', position: 5) }
  let(:front) { 'https://s7d9.scene7.com/is/image/championhomes/belvidere-exterior-1' }

  def model(factory, number, photos: [front])
    plan = CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Belvidere', slug: "belvidere-#{number}".downcase)
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: number, width_ft: 28, length_ft: 56,
                               media: { 'photos' => photos.map { |u| { 'url' => u, 'room' => 'exterior' } } }).tap do |v|
      CatalogVariantPrice.create!(price_book: book, variant: v, net_base_price: 90_000)
    end
  end

  def color(set, name)
    o = CatalogOption.create!(group: exterior, manufacturer: mfr, key: "exterior--#{set}-#{name}".parameterize, name: name,
                              kind: 'color', metadata: { 'color_set' => set })
    CatalogOptionPrice.create!(price_book: book, option: o, is_standard: true)
  end

  # The same Belvidere from two factories, with the same photos, and one with none.
  let!(:topeka_home) { model(topeka, '2856H32392') }
  let!(:decatur_home) { model(decatur, '2856H32393') }
  let!(:no_photos) { model(topeka, '2856H32394', photos: []) }

  before do
    color('Siding', 'White')
    color('Siding', 'Clay')
    color('Shutters', 'Black')
  end

  around do |ex|
    old = ENV['GEMINI_API_KEY']
    ENV['GEMINI_API_KEY'] = 'test'
    ex.run
  ensure
    ENV['GEMINI_API_KEY'] = old
  end

  let(:everything) { described_class.variants(manufacturer_id: mfr.id) }

  it 'covers every priced model, or one factory' do
    expect(everything).to eq([topeka_home, decatur_home, no_photos])
    expect(described_class.variants(manufacturer_id: mfr.id, factory_id: decatur.id)).to eq([decatur_home])
  end

  it 'counts a model two factories carry once, and nothing for a model without photos' do
    estimate = described_class.estimate(everything)
    by = estimate[:models].index_by { |m| m[:id] }
    expect(by[topeka_home.id]).to include(photos: 1, drawings: 3, shared: 0, outlines: 2)
    expect(by[decatur_home.id]).to include(photos: 1, drawings: 0, shared: 3, outlines: 0)
    expect(by[no_photos.id]).to include(photos: 0, drawings: 0, cost_usd: 0.0, note: 'No photos')
    expect(estimate[:totals]).to include(models: 3, with_photos: 2, drawings: 3, shared: 3, outlines: 2, cost_usd: 0.24)
  end

  it 'queues each drawing once across factories, behind buyers, outside the daily limit for buyers' do
    ENV['TRUEVIEW_DAILY_LIMIT'] = '0'
    run = described_class.start!(everything, budget_usd: 5, scope: { manufacturer_id: mfr.id })
    expect { TruebuildFactoryRunJob.perform_now(run.id) }.to have_enqueued_job(TruebuildRenderJob).on_queue('low').exactly(3).times
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == TruebuildRenderJob }.map { |j| j[:priority] }.uniq)
      .to eq([described_class::PRIORITY])
    expect(run.renders.count).to eq(3)
    expect(run.renders.pluck(:catalog_plan_variant_id).uniq).to eq([topeka_home.id])

    progress = described_class.progress(run.reload)
    expect(progress).to include(phase: 'drawing', models: 3, models_queued: 3, committed_usd: 0.24)
    expect(progress[:drawings]).to include(waiting: 3)

    run.stop!
    expect(described_class.progress(run)).to include(phase: 'stopped')
    expect(run.renders.pluck(:status).uniq).to eq(['cancelled'])
  ensure
    ENV.delete('TRUEVIEW_DAILY_LIMIT')
  end

  it 'stops before a model that would go over budget' do
    run = described_class.start!(everything, budget_usd: 0.1, scope: { manufacturer_id: mfr.id })
    TruebuildFactoryRunJob.perform_now(run.id)
    expect(run.reload.status).to eq('budget_reached')
    expect(run.renders.count).to eq(0)
  end

  describe 'repair rounds' do
    let(:run) { described_class.start!(everything, budget_usd: 5, scope: { manufacturer_id: mfr.id }) }
    let(:version) { Truebuild::Trueview::Layer::VERSION }

    before do
      TruebuildFactoryRunJob.perform_now(run.id)
      run.renders.update_all(status: 'done', layer_url: 'https://b/l.webp', usage: { 'factory_run_id' => run.id, 'mask_version' => version })
    end

    def held(value, note)
      run.renders.find_by("selection->0->>'value' = ?", value)
         .update!(status: 'rejected', usage: { 'factory_run_id' => run.id, 'mask_version' => version, 'reviewer_note' => 'Paint on the trim.',
                                               'check' => { 'note' => note } })
    end

    it 'draws a held-back finish again on the larger model with every note, for two rounds' do
      held('Clay', 'The porch wall kept the old siding.')
      expect { described_class.drawing_finished!(run.reload) }.to have_enqueued_job(TruebuildFactoryRunRepairJob).with(run.id)
      expect { described_class.drawing_finished!(run.reload) }.not_to have_enqueued_job(TruebuildFactoryRunRepairJob)

      expect(described_class.repair!(run.reload)).to eq(1)
      again = run.renders.find_by(status: 'queued')
      expect(again.usage).to include('reviewer_note' => 'Paint on the trim. Also: The porch wall kept the old siding.', 'repair_round' => 1,
                                     'draw_with' => 'nb2')
      expect(again.model_key).to eq('nb2-lite')
      expect(described_class.progress(run.reload)).to include(phase: 'repairing', repair: { rounds: 1, redrawn: 1 })

      again.update!(status: 'rejected', usage: again.usage.merge('mask_version' => version, 'escalated' => true, 'check' => { 'note' => 'Still patchy.' }))
      described_class.drawing_finished!(run.reload)
      described_class.repair!(run.reload)
      last = run.renders.find_by(status: 'queued')
      expect(last.usage).to include('draw_with' => 'nb2', 'repair_round' => 2)
      expect(last.usage['reviewer_note']).to end_with('Also: Still patchy.')

      last.update!(status: 'done', layer_url: 'https://b/l2.webp', usage: last.usage.merge('mask_version' => version))
      expect { described_class.drawing_finished!(run.reload) }.not_to have_enqueued_job(TruebuildFactoryRunRepairJob)
      expect(described_class.progress(run.reload)[:phase]).to eq('finished')
    end

    it 'stops repairing at the budget' do
      held('Clay', 'Patchy.')
      run.update!(budget_usd: run.renders.sum(:cost_usd).to_f + 0.01)
      expect(described_class.repair!(run.reload)).to eq(0)
      expect(run.renders.where(status: 'rejected').count).to eq(1)
    end

    it 'outlines again a surface Claude found but rejected the outline of, then draws what it skipped' do
      mask = TruebuildSurfaceMask.create!(source_url: front, surface: 'shutters', version: Truebuild::Trueview::Surfaces::VERSION,
                                          status: 'done', coverage: 0, mask_url: 'https://b/m.png', error: 'It took in the windows.',
                                          usage: { 'attempts' => [{ 'present' => true, 'fit' => 2 }] })
      run.renders.find_by("selection->0->>'surface' = 'Shutters'").update!(status: 'skipped')
      allow(Truebuild::Trueview).to receive(:fetch_source).and_return(bytes: 'x', mime: 'image/jpeg')
      expect(Truebuild::Trueview::Surfaces).to receive(:find!).with(front, 'x', 'shutters', correction: 'It took in the windows.')
        .and_return(TruebuildSurfaceMask.new(status: 'done', coverage: 0.05, mask_url: 'https://b/n.png', usage: { 'cost_usd' => 0.05 }))
      allow_any_instance_of(Truebuild::Trueview::Buyer).to receive(:queue_missing!).and_return(1)

      described_class.repair!(run.reload)
      expect(TruebuildSurfaceMask.exists?(mask.id)).to be(false)
      expect(run.renders.find_by("selection->0->>'surface' = 'Shutters'").status).to eq('superseded')
      expect(run.reload.progress['outline_repair_usd']).to eq(0.05)
    end
  end

  it "reuses Claude's photo pick for a model with the same photos" do
    second = "#{front}-2"
    topeka_home.update!(media: { 'photos' => [front, second].map { |u| { 'url' => u, 'room' => 'exterior' } },
                                 'trueview_auto' => { 'exterior' => second } })
    decatur_home.update!(media: { 'photos' => [front, second].map { |u| { 'url' => u, 'room' => 'exterior' } } })
    expect(Catalog::PriceBooks::ClaudeClient).not_to receive(:call)

    Truebuild::Trueview::PhotoChoice.pick!(decatur_home)
    expect(decatur_home.reload.media.dig('trueview_auto', 'exterior')).to eq(second)
  end
end
