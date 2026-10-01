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
