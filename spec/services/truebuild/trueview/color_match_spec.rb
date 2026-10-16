# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::ColorMatch do
  # A grained warm brown on the left half (the drawn cabinets), grey on the right that is not the surface.
  let(:drawn) do
    grain = Vips::Image.gaussnoise(100, 100, sigma: 12, mean: 0)
    left = (grain + [120, 80, 50]).cast(:uchar)
    right = (Vips::Image.black(100, 100, bands: 3) + [60, 60, 60]).cast(:uchar)
    left.join(right, :horizontal).copy(interpretation: :srgb)
  end
  let(:photo) { (Vips::Image.black(200, 100, bands: 3) + [90, 90, 90]).cast(:uchar) }
  let(:mask) { (Vips::Image.black(200, 100) + 0).draw_rect(255, 0, 0, 100, 100, fill: true).cast(:uchar) }

  def means(img, x, w) = (0..2).map { |i| img.crop(x, 10, w, 80).extract_band(i).avg }

  it "moves the drawn surface to the sample's color, keeping its grain, and leaves the rest alone" do
    out = Vips::Image.new_from_buffer(described_class.correct(photo.jpegsave_buffer, drawn.pngsave_buffer, mask, '#686155')[:bytes], '')
    left = means(out, 10, 80)
    tint = Truebuild::Trueview::Tint.target_linear('#686155').map { |c| c * Truebuild::Trueview::Tint::EXPOSURE }
    expected = tint.map { |c| ((c <= 0.0031308 ? c * 12.92 : 1.055 * (c**(1 / 2.4)) - 0.055) * 255) }

    left.zip(expected).each { |got, want| expect(got).to be_within(6).of(want) }
    expect(out.crop(10, 10, 80, 80).extract_band(0).deviate).to be > 4 # the grain survived
    means(out, 110, 80).each { |v| expect(v).to be_within(2).of(60) }
  end

  it 'leaves a drawing that is the wrong finish altogether, not the wrong shade' do
    black = (Vips::Image.black(200, 100, bands: 3) + [3, 3, 3]).cast(:uchar)
    expect(described_class.correct(photo.jpegsave_buffer, black.pngsave_buffer, mask, '#eff0e5')).to be_nil
  end

  it 'writes a learned linear color back as a hex a sample would have' do
    linear = Truebuild::Trueview::Tint.target_linear('#686155')
    expect(described_class.to_hex(linear)).to eq('#686155')
  end
end
