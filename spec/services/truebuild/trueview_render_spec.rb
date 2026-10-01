# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'TrueView rendering' do
  let(:photo) { (Vips::Image.black(300, 200, bands: 3) + [150, 140, 130]).cast(:uchar) }
  let(:render) do
    TruebuildRender.create!(source_url: 'https://x/kitchen.jpg', selection: [{ 'surface' => 'Cabinets', 'value' => 'Destin White' }],
                            selection_key: 'k', model_key: 'nb2-lite', provider: 'gemini', model: 'gemini-3.1-flash-lite-image',
                            purpose: 'layer', prompt: 'p')
  end

  def png(image) = image.cast(:uchar).pngsave_buffer

  before do
    allow(Truebuild::Trueview).to receive(:fetch_source) { |url| { bytes: url.include?('mask') ? @mask_png : photo.jpegsave_buffer, mime: 'image/jpeg' } }
    allow(Truebuild::Trueview).to receive(:store) { |_r, _b, _m, **o| "https://b/#{o[:suffix] || 'full'}" }
    allow(Truebuild::Trueview).to receive(:store_bytes) { |_b, _m, key| "https://b/#{key}" }
  end

  describe 'surface outlines' do
    it "paints Gemini's boxes and probability maps into one full-size mask" do
      box_mask = Base64.strict_encode64(png(Vips::Image.black(10, 10) + 255))
      masks = [{ 'box_2d' => [0, 0, 500, 500], 'mask' => "data:image/png;base64,#{box_mask}" }]
      mask = Truebuild::Trueview::Surfaces.paint(masks, 300, 200)
      expect(mask.avg / 255.0).to be_within(0.01).of(0.25)
    end

    it 'falls back rather than skipping when the model gives boxes without outlines, and tries again later' do
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:segment)
        .and_return(masks: [{ 'box_2d' => [0, 0, 500, 500] }], model: 'gemini-x', usage: {})
      mask = Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', photo.jpegsave_buffer, 'Cabinets')
      expect(mask).to have_attributes(status: 'failed', error: 'gemini-x returned boxes but no outlines')
      expect(mask.present?).to be(false)

      mask.update_columns(updated_at: 1.hour.ago)
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:segment).and_return(masks: [], model: 'gemini-x', usage: {})
      expect(Truebuild::Trueview::Surfaces.mask_for('https://x/k.jpg', photo.jpegsave_buffer, 'Cabinets').status).to eq('done')
    end

    it 'skips a surface the photo does not show, without paying for a drawing' do
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:segment).and_return(masks: [], model: 'gemini-2.5-flash', usage: {})
      expect(Truebuild::Trueview::Providers::Gemini).not_to receive(:edit)
      Truebuild::Trueview.perform!(render)
      expect(render.reload).to have_attributes(status: 'skipped', error: 'Not in this photo')
      expect(TruebuildSurfaceMask.last).to have_attributes(surface: 'cabinets', coverage: 0)
    end

    it 'keeps only the drawing inside the outline, whatever else the model changed' do
      # The outline is the left half; the model also changed the right half.
      @mask_png = png((Vips::Image.black(300, 200) + 0).draw_rect(255, 0, 0, 150, 200, fill: true))
      TruebuildSurfaceMask.create!(source_url: render.source_url, surface: 'cabinets', mask_url: 'https://b/mask.png', coverage: 0.5)
      drawn = (photo + 60).cast(:uchar)
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit)
        .and_return(bytes: png(drawn), mime: 'image/png', usage: { 'prompt_tokens' => 10, 'output_tokens' => 1300 })
      Truebuild::Trueview.perform!(render)
      expect(render.reload.status).to eq('done')
      expect(render.mask_coverage.to_f).to be_within(0.01).of(0.5)
    end
  end

  describe 'framing' do
    before { allow(Truebuild::Trueview::Surfaces).to receive(:mask_for).and_return(nil) }

    it 'asks for the photo shape and draws again when the model reframes, paying for both' do
      tall = png(Vips::Image.black(100, 300, bands: 3) + 90)
      wide = png((photo + 30).cast(:uchar))
      calls = 0
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit) do |*_, aspect:, **|
        expect(aspect).to eq(1.5)
        calls += 1
        { bytes: calls == 1 ? tall : wide, mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 } }
      end
      Truebuild::Trueview.perform!(render)
      expect(render.reload.status).to eq('done')
      expect(render.cost_usd.to_f).to eq(0.06) # two drawings at 1,000 tokens x $30/M
    end

    it 'gives up after two reframed drawings' do
      tall = png(Vips::Image.black(100, 300, bands: 3) + 90)
      allow(Truebuild::Trueview::Providers::Gemini).to receive(:edit)
        .and_return(bytes: tall, mime: 'image/png', usage: { 'prompt_tokens' => 0, 'output_tokens' => 1000 })
      Truebuild::Trueview.perform!(render)
      expect(render.reload).to have_attributes(status: 'failed', error: "The model changed the photo's framing 2 times")
    end
  end

  it 'picks the closest aspect Gemini offers' do
    allow(Truebuild::Trueview::Providers::Gemini).to receive(:resolve) { |m| m }
    allow(Truebuild::Trueview::Providers::Gemini).to receive(:headers).and_return({})
    sent = nil
    allow(HTTParty).to receive(:post) { |_url, opts| sent = JSON.parse(opts[:body]); double(code: 500, parsed_response: {}, body: 'x') }
    expect do
      Truebuild::Trueview::Providers::Gemini.edit({ model: 'm', size: nil }, { bytes: 'x', mime: 'image/jpeg' }, 'p', aspect: 1600 / 1069.0)
    end.to raise_error(Truebuild::Trueview::Error)
    expect(sent.dig('generationConfig', 'imageConfig', 'aspectRatio')).to eq('3:2')
  end
end
