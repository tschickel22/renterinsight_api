# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::Patterns do
  include ActiveJob::TestHelper

  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:topeka) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: topeka, name: 'Topeka 2026', status: 'published') }
  let(:exterior) { CatalogOptionGroup.create!(manufacturer: mfr, factory: topeka, key: 'exterior', name: 'Exterior', position: 5) }
  let(:front) { 'https://s7d9.scene7.com/is/image/championhomes/belvidere-exterior-1' }
  let(:photo) { (Vips::Image.black(300, 200, bands: 3) + [150, 140, 130]).cast(:uchar) }
  let(:outline) { (Vips::Image.black(300, 200) + 0).draw_rect(255, 0, 0, 150, 100, fill: true).cast(:uchar) }
  let!(:home) do
    plan = CatalogPlan.create!(manufacturer: mfr, factory: topeka, series: 'Aspire', name: 'Belvidere', slug: "b-#{SecureRandom.hex(2)}")
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32392', width_ft: 28, length_ft: 56,
                               media: { 'photos' => [{ 'url' => front, 'room' => 'exterior' }] }).tap do |v|
      CatalogVariantPrice.create!(price_book: book, variant: v, net_base_price: 90_000)
    end
  end
  let(:run) { Truebuild::Trueview::FactoryRun.start!([home], budget_usd: 5, scope: { manufacturer_id: mfr.id }) }
  let!(:mask) do
    TruebuildSurfaceMask.create!(source_url: front, surface: 'siding', version: Truebuild::Trueview::Surfaces::VERSION, status: 'done',
                                 mask_url: 'https://b/masks/siding.png', coverage: 0.25)
  end

  around do |ex|
    old = ENV['GEMINI_API_KEY']
    ENV['GEMINI_API_KEY'] = 'test'
    ex.run
  ensure
    ENV['GEMINI_API_KEY'] = old
  end

  before do
    %w[White Clay Olive Wedgewood].each do |name|
      o = CatalogOption.create!(group: exterior, manufacturer: mfr, key: "exterior--siding-#{name}".downcase, name: name,
                                kind: 'color', metadata: { 'color_set' => 'Siding' })
      CatalogOptionPrice.create!(price_book: book, option: o, is_standard: true)
    end
    allow(Truebuild::Trueview).to receive(:fetch_source) do |url|
      { bytes: url.include?('masks/') ? outline.pngsave_buffer : photo.jpegsave_buffer, mime: 'image/jpeg' }
    end
    TruebuildFactoryRunJob.perform_now(run.id)
    run.renders.each_with_index do |r, i|
      r.update!(status: i.zero? ? 'done' : 'rejected', image_url: "https://b/d#{i}.png", layer_url: "https://b/l#{i}.webp",
                usage: r.usage.merge('mask_version' => Truebuild::Trueview::Layer::VERSION,
                                     'check' => { 'note' => 'The porch wall section was left in the old color.' }))
    end
  end

  def claude_says(input)
    allow(Catalog::PriceBooks::ClaudeClient).to receive(:call).and_return(input: input, input_tokens: 2000, output_tokens: 60)
  end

  it 'redoes an outline several colors failed the same way on, and cuts those drawings again instead of redrawing them' do
    claude_says('cause' => 'outline', 'outline_note' => 'Include the porch wall under the overhang.', 'summary' => 'The outline misses the porch wall.')
    expect { Truebuild::Trueview::FactoryRun.repair!(run.reload) }.to have_enqueued_job(TruebuildOutlineRedoJob)
      .with(mask.id, 'Include the porch wall under the overhang.')
    expect(mask.reload.usage['pattern_redo']).to be(true)
    expect(run.reload.progress['patterns'].sole).to include('surface' => 'siding', 'held' => 3, 'of' => 4, 'cause' => 'outline')
    # Held back on that outline: cut again after the redo, not redrawn now.
    expect(run.renders.where("usage->>'draw_with' = 'nb2'")).to be_empty
  end

  it 'records a cause redrawing cannot fix, for the lab and the end-of-run notice' do
    claude_says('cause' => 'drawing', 'summary' => 'The model cannot render this lap siding texture.')
    expect { described_class.review!(run.reload) }.not_to have_enqueued_job(TruebuildOutlineRedoJob)
    expect(run.reload.pattern_note).to include('The model cannot render this lap siding texture.')
  end

  it 'leaves an outline alone once it was redone for a pattern' do
    mask.update_columns(usage: { 'pattern_redo' => true })
    expect(Catalog::PriceBooks::ClaudeClient).not_to receive(:call)
    expect(described_class.review!(run.reload)).to eq([])
  end
end
