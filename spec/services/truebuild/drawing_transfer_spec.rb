# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::DrawingTransfer do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:topeka) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: topeka, series: 'Aspire', name: 'Belvidere') }
  let(:photo) { 'https://s7d9.scene7.com/is/image/championhomes/belvidere-kitchen-1' }
  let!(:variant) do
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32392', width_ft: 28, length_ft: 56,
                               media: { 'photos' => [{ 'url' => photo, 'room' => 'kitchen' }],
                                        'trueview_photos' => { 'kitchen' => [photo] }, 'hidden_photos' => ['https://x/old.jpg'] })
  end
  let(:staging) { 'https://renterinsight-website-assets-staging.s3.us-west-2.amazonaws.com/truebuild' }

  before do
    CatalogSwatch.create!(manufacturer: mfr, factory: topeka, set_name: 'Cabinets', name: 'Destin White', hex: '#eff0e5',
                          image_url: "#{staging}/swatches/destin.png")
    TruebuildSurfaceMask.create!(source_url: photo, surface: 'cabinets', version: 14, mask_url: "#{staging}/masks/cab.png",
                                 coverage: 0.2, usage: { 'scope' => 'x' })
    TruebuildRender.create!(catalog_plan_variant: variant, source_url: photo, room: 'kitchen', purpose: 'layer', status: 'done',
                            selection: [{ 'surface' => 'Cabinets', 'value' => 'Destin White' }], selection_key: 'k1',
                            model_key: 'nb2-lite', provider: 'gemini', model: 'lite', prompt: 'p', cost_usd: 0.04,
                            image_url: "#{staging}/trueview/k1.jpg", layer_url: "#{staging}/trueview/k1-layer.webp",
                            usage: { 'mask_version' => 21, 'swatch_ids' => [7] })
    TruebuildRender.create!(source_url: photo, purpose: 'layer', status: 'done', lab_run: 'lab', selection: [], selection_key: 'lab',
                            model_key: 'nb2-lite', provider: 'gemini', model: 'lite')
    # The receiving side's own bucket.
    allow(described_class).to receive(:rehost) { |url| url&.sub('website-assets-staging', 'website-assets') }
  end

  def round_trip(kind)
    described_class.export(kind)[:rows].map { |r| JSON.parse(r.to_json) } # as it travels
  end

  it 'carries samples, photo choices, outlines and drawings by what they are, into its own bucket, once' do
    exported = described_class::KINDS.index_with { |k| round_trip(k) }
    expect(exported['renders'].size).to eq(1) # not the lab's
    CatalogSwatch.delete_all
    TruebuildSurfaceMask.delete_all
    TruebuildRender.delete_all
    variant.update_columns(media: variant.media.except('trueview_photos', 'hidden_photos'))

    results = exported.to_h { |k, rows| [k, described_class.import!(k, rows)] }
    expect(results.values.map { |r| r[:skipped] }).to all(be_empty)
    expect(CatalogSwatch.sole).to have_attributes(factory_id: topeka.id, name: 'Destin White', image_url: include('website-assets.s3'))
    expect(variant.reload.media).to include('trueview_photos' => { 'kitchen' => [photo] }, 'hidden_photos' => ['https://x/old.jpg'])
    expect(TruebuildSurfaceMask.sole).to have_attributes(surface: 'cabinets', version: 14, mask_url: include('website-assets.s3'))
    render = TruebuildRender.sole
    expect(render).to have_attributes(catalog_plan_variant_id: variant.id, prompt: 'p', layer_url: include('website-assets.s3.'))
    expect(render.usage).not_to have_key('swatch_ids')

    again = exported.to_h { |k, rows| [k, described_class.import!(k, rows)] }
    expect(again.values.sum { |r| r[:created] }).to eq(0)
    expect([CatalogSwatch.count, TruebuildSurfaceMask.count, TruebuildRender.count]).to eq([1, 1, 1])
  end

  it 'links a drawing copied before its model existed when run again' do
    rows = round_trip('renders')
    TruebuildRender.delete_all
    stash = variant.model_number
    variant.update_columns(model_number: 'NOT-YET')
    described_class.import!('renders', rows)
    expect(TruebuildRender.sole.catalog_plan_variant_id).to be_nil

    variant.update_columns(model_number: stash) # the price book arrives
    described_class.import!('renders', rows)
    expect(TruebuildRender.sole.catalog_plan_variant_id).to eq(variant.id)
  end

  it 'carries every attempt at a drawing, not only the first' do
    first = TruebuildRender.find_by(selection_key: 'k1')
    first.update_columns(status: 'rejected', usage: first.usage.merge('mask_version' => 20))
    TruebuildRender.create!(first.attributes.except('id', 'created_at', 'updated_at').merge('status' => 'done', 'usage' => { 'mask_version' => 21 }))
    rows = round_trip('renders')
    TruebuildRender.delete_all
    described_class.import!('renders', rows)
    expect(TruebuildRender.where(selection_key: 'k1').pluck(:status)).to contain_exactly('rejected', 'done')
  end

  it 'says what it could not place' do
    rows = round_trip('photos').map { |r| r.merge('model_number' => 'NOPE') }
    expect(described_class.import!('photos', rows)[:skipped].sole).to include('no model')
  end
end
