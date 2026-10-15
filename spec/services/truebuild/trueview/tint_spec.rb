# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::Tint do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  # Grey siding on the left half, lit on top and in shade below; a dark right half that is not siding.
  let(:photo) do
    img = (Vips::Image.black(200, 100, bands: 3) + [40, 40, 40]).cast(:uchar)
    img = img.draw_rect([150, 150, 150], 0, 0, 100, 50, fill: true)
    img.draw_rect([75, 75, 75], 0, 50, 100, 50, fill: true).cast(:uchar)
  end
  let(:mask) { (Vips::Image.black(200, 100) + 0).draw_rect(255, 0, 0, 100, 100, fill: true).cast(:uchar) }
  let(:flat_sample) { ((Vips::Image.black(100, 100, bands: 3) + [120, 30, 30])).cast(:uchar) }
  let(:grain_sample) { ((Vips::Image.gaussnoise(100, 100, sigma: 25, mean: 128)).bandjoin([Vips::Image.gaussnoise(100, 100, sigma: 25, mean: 110)] * 2)).cast(:uchar) }

  def swatch(set, name, hex, url: "https://b/#{SecureRandom.hex(3)}.jpg")
    CatalogSwatch.create!(manufacturer: mfr, set_name: set, name: name, hex: hex, image_url: url)
  end

  def finish(surface, value) = [{ 'surface' => surface, 'value' => value }]

  def enable! = Setting.set('platform', nil, described_class::SETTING, true)

  before do
    allow(Truebuild::Trueview).to receive(:fetch_source) do |url|
      bytes = if url.include?('grain') then grain_sample.jpegsave_buffer
              elsif url.include?('mask') then mask.pngsave_buffer
              elsif url.include?('/b/') then flat_sample.jpegsave_buffer
              else photo.jpegsave_buffer
              end
      { bytes: bytes, mime: 'image/jpeg' }
    end
    allow(Truebuild::Trueview).to receive(:store) { |_r, _b, _m, **o| "https://b/#{o[:suffix]}" }
  end

  it 'lays the sample color inside the outline, keeping light and shade, and leaves the rest of the photo alone' do
    out = Vips::Image.new_from_buffer(described_class.paint(photo.jpegsave_buffer, mask, '#8c3a2e')[:bytes], '')
    means = ->(x, y, w, h) { region = out.crop(x, y, w, h); (0..2).map { |i| region.extract_band(i).avg } }
    lit = means.call(10, 10, 80, 30)
    shade = means.call(10, 60, 80, 30)
    rest = means.call(110, 10, 80, 80)

    expect(lit[0]).to be > lit[1] + 40 # red, not grey
    expect(shade.sum).to be < lit.sum  # still in shade
    rest.each { |v| expect(v).to be_within(3).of(40) }
  end

  it 'tints only plain colors from a factory sample: never a texture, a shake, a guess from the name, or when turned off' do
    plain = swatch('Standard Vinyl Siding', 'Clay', '#8c887d')
    painted = swatch('Shaker Style Cabinets', 'Destin White', '#eff0e5')
    oak = swatch('Shaker Style Cabinets', 'Urban Oak', '#a7947b', url: 'https://b/grain-oak.jpg')
    shake = swatch('Optional Shake Accent', 'Pewter', '#7a7b79')

    expect(described_class.hex_for(finish('Siding', 'Clay'), plain.id)).to eq('#8c887d')
    expect(described_class.hex_for(finish('Cabinets', 'Destin White'), painted.id)).to eq('#eff0e5')
    expect(described_class.hex_for(finish('Cabinets', 'Urban Oak'), oak.id)).to be_nil
    expect(described_class.hex_for(finish('Siding', 'Pewter'), shake.id)).to be_nil
    expect(described_class.hex_for(finish('Countertop', 'Clay'), plain.id)).to be_nil
    expect(described_class.hex_for(finish('Siding', 'Clay'), nil)).to be_nil

    render = TruebuildRender.new(purpose: 'layer', selection: finish('Siding', 'Clay'), usage: { 'swatch_ids' => [plain.id] })
    expect(described_class.color_for(render)).to be_nil
    enable!
    expect(described_class.color_for(render)).to eq('#8c887d')
    render.usage['tint_failed'] = true
    expect(described_class.color_for(render)).to be_nil
  end

  describe 'drawing a layer' do
    let(:clay) { swatch('Standard Vinyl Siding', 'Clay', '#8c887d') }
    let(:render) do
      TruebuildRender.create!(source_url: 'https://x/front.jpg', selection: finish('Siding', 'Clay'), selection_key: 'k', model_key: 'nb2-lite',
                              provider: 'gemini', model: 'gemini-3.1-flash-lite-image', purpose: 'layer', prompt: 'p',
                              usage: { 'swatch_ids' => [clay.id] })
    end
    let(:score) { 5 }

    before do
      enable!
      TruebuildSurfaceMask.create!(source_url: 'https://x/front.jpg', surface: 'siding', version: Truebuild::Trueview::Surfaces::VERSION,
                                   mask_url: 'https://b/mask.png', coverage: 0.5, status: 'done')
      TruebuildSurfaceMask.create!(source_url: 'https://x/front.jpg', surface: 'gable cladding', version: Truebuild::Trueview::Surfaces::VERSION,
                                   coverage: 0, status: 'done') # this front has none
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) { { input: { 'score' => score, 'note' => 'off' }, input_tokens: 1000, output_tokens: 50 } }
    end

    it 'lays a plain color with no image model, paying only for its check' do
      expect(Truebuild::Trueview::Providers::Gemini).not_to receive(:edit)
      Truebuild::Trueview.perform!(render)
      expect(render.reload).to have_attributes(status: 'done', model: 'tint', layer_url: 'https://b/tint-layer')
      expect(render.usage).to include('tinted' => true, 'tint_hex' => '#8c887d')
      expect(render.cost_usd.to_f).to be < 0.02
    end

    context 'when the tint fails its check' do
      let(:score) { 2 }

      it 'draws it instead, and counts what the check cost' do
        expect(Truebuild::Trueview::Providers::Gemini).to receive(:edit).at_least(:once)
          .and_return(bytes: (photo + 30).cast(:uchar).pngsave_buffer, mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 })
        Truebuild::Trueview.perform!(render)
        expect(render.reload.usage).to include('tint_failed' => true)
        expect(render.model).not_to eq('tint')
      end
    end
  end

  describe 'siding with a gable accent' do
    let(:clay) { swatch('Standard Vinyl Siding', 'Clay', '#8c887d') }
    let(:render) do
      TruebuildRender.create!(source_url: 'https://x/front.jpg', selection: finish('Siding', 'Clay'), selection_key: 'k', model_key: 'nb2-lite',
                              provider: 'gemini', model: 'gemini-3.1-flash-lite-image', purpose: 'layer', prompt: 'p',
                              usage: { 'swatch_ids' => [clay.id] })
    end
    let(:siding) do
      TruebuildSurfaceMask.create!(source_url: 'https://x/front.jpg', surface: 'siding', version: Truebuild::Trueview::Surfaces::VERSION,
                                   mask_url: 'https://b/mask.png', coverage: 0.5, status: 'done')
    end
    let(:ctx) { { source: { bytes: photo.jpegsave_buffer }, mask: siding, check_with: {} } }

    before do
      allow(Catalog::PriceBooks::ClaudeClient).to receive(:call) { { input: { 'score' => 5 }, input_tokens: 1000, output_tokens: 50 } }
    end

    it 'leaves the accent as it was' do
      accent = TruebuildSurfaceMask.new(surface: 'gable cladding', status: 'done', mask_url: 'https://b/accent.png', coverage: 0.25)
      allow(accent).to receive(:present?).and_return(true)
      allow(Truebuild::Trueview::Surfaces).to receive(:mask_for).and_return(accent)
      allow(Truebuild::Trueview).to receive(:mask_image) do |m|
        m.surface == 'gable cladding' ? (Vips::Image.black(200, 100) + 0).draw_rect(255, 0, 0, 100, 50, fill: true).cast(:uchar) : mask
      end
      painted = nil
      allow(described_class).to receive(:paint).and_wrap_original { |orig, b, m, h| painted = m; orig.call(b, m, h) }

      expect(described_class.apply!(render, ctx, '#8c887d')).to be(true)
      expect(painted.crop(10, 10, 80, 30).avg).to eq(0)      # the accent (top) left out
      expect(painted.crop(10, 60, 80, 30).avg).to eq(255)    # the lap siding below tinted
    end

    it 'draws the siding instead when it could not be settled whether the photo has an accent' do
      allow(Truebuild::Trueview::Surfaces).to receive(:mask_for).and_return(TruebuildSurfaceMask.new(surface: 'gable cladding', status: 'failed'))
      expect(described_class.apply!(render, ctx, '#8c887d')).to be(false)
    end
  end
end
