# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::Touchup do
  # A 200x100 photo: grey cabinets on the left half (the outline), white wall on the right.
  let(:photo) do
    grain = (Vips::Image.gaussnoise(100, 100, sigma: 6, mean: 128)).cast(:uchar)
    left = grain.bandjoin([grain, grain])
    right = (Vips::Image.black(100, 100, bands: 3) + [235, 235, 235]).cast(:uchar)
    left.join(right, :horizontal).copy(interpretation: :srgb)
  end
  let(:outline) { (Vips::Image.black(200, 100) + 0).draw_rect(255, 0, 0, 100, 100, fill: true).cast(:uchar) }
  let(:mask) { instance_double(TruebuildSurfaceMask, present?: true, surface: 'cabinets', usage: {}, source_url: 'p') }

  def rgb(bytes) = Vips::Image.new_from_buffer(bytes, '')
  def means(img, x, w) = (0..2).map { |i| img.crop(x, 10, w, 80).extract_band(i).avg }

  before do
    allow(Truebuild::Trueview).to receive(:mask_image).and_return(outline)
    allow(Truebuild::Trueview).to receive(:blocked_image).and_return(nil)
    allow(Truebuild::Trueview::ColorMatch).to receive(:learned_hex).and_return(nil)
  end

  it 'carries the change the drawing made onto the part of the outline it skipped, then keeps it if the check passes' do
    # Drawn: the top 60 rows of the cabinets turned warm brown, the bottom 40 left grey.
    drawn = photo.copy
    drawn = drawn.insert(((photo.crop(0, 0, 100, 60).cast(:float) * [0.9, 0.6, 0.35]).cast(:uchar)), 0, 0)
    allow(Truebuild::Trueview::LayerCheck).to receive(:judge).and_return('ok' => true, 'score' => 5, 'cost_usd' => 0.01)

    result, _layer, verdict, cost = described_class.settle(
      photo.jpegsave_buffer, { bytes: drawn.pngsave_buffer, mime: 'image/png' }, { bytes: 'old' },
      { 'ok' => false, 'note' => 'The lower cabinets remain in the original grey.' }, mask, {}, surface: 'Cabinets', value: 'Ozark Shadow'
    )
    out = rgb(result[:bytes])
    top = (0..2).map { |i| out.crop(10, 5, 80, 50).extract_band(i).avg }
    bottom = (0..2).map { |i| out.crop(10, 65, 80, 30).extract_band(i).avg }
    bottom.zip(top).each { |b, t| expect(b).to be_within(8).of(t) }
    expect(means(out, 110, 80)).to all(be_within(2).of(235)) # the wall is left alone
    expect([verdict['touched'], cost]).to eq([['filled'], 0.01])
  end

  it 'keeps the drawing as it was when the touched one fails its check too, charging the check' do
    drawn = photo.insert((photo.crop(0, 0, 100, 60).cast(:float) * [0.9, 0.6, 0.35]).cast(:uchar), 0, 0)
    allow(Truebuild::Trueview::LayerCheck).to receive(:judge).and_return('ok' => false, 'note' => 'streaked', 'cost_usd' => 0.01)
    held = { 'ok' => false, 'note' => 'The lower cabinets remain grey.' }
    result, layer, verdict, cost, = described_class.settle(photo.jpegsave_buffer, { bytes: drawn.pngsave_buffer }, { bytes: 'old' },
                                                          held, mask, {}, surface: 'Cabinets', value: 'Ozark Shadow')
    expect([result[:bytes] == drawn.pngsave_buffer, layer, verdict, cost]).to eq([true, { bytes: 'old' }, held, 0.01])
  end

  describe 'a floor set to its sample color' do
    let(:mask) { instance_double(TruebuildSurfaceMask, present?: true, surface: 'flooring', usage: {}, source_url: 'p') }
    let(:drawn) { (photo.cast(:float) * [1.1, 1.0, 0.8]).cast(:uchar) }
    let(:held) { { 'ok' => false, 'note' => 'Too warm and golden against the sample.' } }

    def settle
      described_class.settle(photo.jpegsave_buffer, { bytes: drawn.pngsave_buffer }, { bytes: 'old' }, held, mask,
                             { hex: '#B9B19F' }, surface: 'Flooring', value: 'Texas Oak')
    end

    before do
      allow(Truebuild::Trueview::LayerCheck).to receive(:judge)
        .and_return('ok' => false, 'score' => 3, 'note' => 'Now too light and washed out.', 'cost_usd' => 0.01)
    end

    it 'passes when nothing of the old floor is left, spilled or added, whatever the check thinks of the shade' do
      allow(Truebuild::Trueview::LayerCheck).to receive(:look_again)
        .and_return('old_finish_left' => 'none', 'spilled_onto' => 'none', 'added_or_changed' => 'none',
                    'color_matches_sample' => false, 'acceptable' => false, 'cost_usd' => 0.02)
      _result, _layer, verdict, cost = settle
      expect(verdict).to include('ok' => true, 'shade_set' => true, 'touched' => ['color_matched'])
      expect(cost).to be_within(0.0001).of(0.03)
    end

    it 'stays held when the old floor shows, or the second look could not run' do
      allow(Truebuild::Trueview::LayerCheck).to receive(:look_again)
        .and_return('old_finish_left' => 'the strip behind the island', 'spilled_onto' => 'none', 'added_or_changed' => 'none', 'cost_usd' => 0.02)
      expect(settle[2]).to eq(held)
      allow(Truebuild::Trueview::LayerCheck).to receive(:look_again).and_return('acceptable' => nil, 'defect' => 'Second look not run', 'cost_usd' => 0)
      expect(settle[2]).to eq(held)
    end

    it 'is not done for other surfaces' do
      allow(Truebuild::Trueview::LayerCheck).to receive(:look_again)
      described_class.settle(photo.jpegsave_buffer, { bytes: drawn.pngsave_buffer }, { bytes: 'old' }, held,
                             instance_double(TruebuildSurfaceMask, present?: true, surface: 'cabinets', usage: {}, source_url: 'p'),
                             { hex: '#B9B19F' }, surface: 'Cabinets', value: 'Putty Grey')
      expect(Truebuild::Trueview::LayerCheck).not_to have_received(:look_again)
    end
  end
end
