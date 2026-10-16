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

    result, _layer, verdict, cost, redone = described_class.settle(
      photo.jpegsave_buffer, { bytes: drawn.pngsave_buffer, mime: 'image/png' }, { bytes: 'old' },
      { 'ok' => false, 'note' => 'The lower cabinets remain in the original grey.' }, mask, {}, surface: 'Cabinets', value: 'Ozark Shadow'
    )
    out = rgb(result[:bytes])
    top = (0..2).map { |i| out.crop(10, 5, 80, 50).extract_band(i).avg }
    bottom = (0..2).map { |i| out.crop(10, 65, 80, 30).extract_band(i).avg }
    bottom.zip(top).each { |b, t| expect(b).to be_within(8).of(t) }
    expect(means(out, 110, 80)).to all(be_within(2).of(235)) # the wall is left alone
    expect([verdict['touched'], cost, redone]).to eq([['filled'], 0.01, false])
  end

  it 'redoes the outline once, and draws nothing, when the drawing changed all of it and old finish was still found' do
    drawn = photo.insert((photo.crop(0, 0, 100, 100).cast(:float) * [0.9, 0.6, 0.35]).cast(:uchar), 0, 0)
    row = TruebuildSurfaceMask.new(usage: {}, surface: 'cabinets')
    allow(row).to receive(:present?).and_return(true)
    allow(row).to receive(:update_columns) { |attrs| row.usage = attrs[:usage] }
    allow(row).to receive(:id).and_return(7)
    expect(TruebuildOutlineRedoJob).to receive(:perform_later).once.with(7, /left out part of the cabinets.*crown molding/)
    expect(Truebuild::Trueview::LayerCheck).not_to receive(:judge)

    held = { 'ok' => false, 'note' => 'The crown molding above the range retains the original oak.' }
    args = [photo.jpegsave_buffer, { bytes: drawn.pngsave_buffer }, { bytes: 'old' }, held, row, {}]
    expect(described_class.settle(*args, surface: 'Cabinets', value: 'Ozark Shadow').last).to be(true)
    expect(described_class.settle(*args, surface: 'Cabinets', value: 'Ozark Shadow').last).to be(false) # once only
  end

  it 'keeps the drawing as it was when the touched one fails its check too, charging the check' do
    drawn = photo.insert((photo.crop(0, 0, 100, 60).cast(:float) * [0.9, 0.6, 0.35]).cast(:uchar), 0, 0)
    allow(Truebuild::Trueview::LayerCheck).to receive(:judge).and_return('ok' => false, 'note' => 'streaked', 'cost_usd' => 0.01)
    held = { 'ok' => false, 'note' => 'The lower cabinets remain grey.' }
    result, layer, verdict, cost, = described_class.settle(photo.jpegsave_buffer, { bytes: drawn.pngsave_buffer }, { bytes: 'old' },
                                                          held, mask, {}, surface: 'Cabinets', value: 'Ozark Shadow')
    expect([result[:bytes] == drawn.pngsave_buffer, layer, verdict, cost]).to eq([true, { bytes: 'old' }, held, 0.01])
  end
end
