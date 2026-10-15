# frozen_string_literal: true

require 'rails_helper'

# The signing pad saves its whole canvas, so a buyer's initials were a small
# mark in a wide empty picture; fitted into a 30x12 box they came out as a
# barely visible tick. The seal crops to the ink first.
RSpec.describe AgreementPdfService, 'drawn marks' do
  let(:service) { described_class.allocate }

  # A 464x120 transparent pad with a 32x51 mark in the middle, like AGR-2026-00057's.
  let(:pad) do
    clear = Vips::Image.black(464, 120, bands: 4)
    mark = (Vips::Image.black(32, 51) + 255).bandjoin([0, 0, 255]).copy(interpretation: :srgb)
    png = clear.copy(interpretation: :srgb).insert(mark, 234, 43).write_to_buffer('.png')
    "data:image/png;base64,#{Base64.strict_encode64(png)}"
  end

  it 'crops a pad to its ink' do
    file = service.send(:decode_base64_image, pad)
    inked = service.send(:ink_only, file.path, 30, 12)
    img = Vips::Image.new_from_file(inked.path)
    expect(img.width).to be < 50
    expect(img.height).to be < 70
  end

  it 'crops a pad drawn on an opaque white canvas' do
    white = (Vips::Image.black(464, 120) + 255).bandjoin([255, 255, 255]).copy(interpretation: :srgb)
    ink = Vips::Image.black(32, 51).bandjoin([0, 0, 255]).copy(interpretation: :srgb)
    file = Tempfile.new(['pad', '.png']).tap { |f| white.insert(ink, 234, 43).write_to_file(f.path) }
    img = Vips::Image.new_from_file(service.send(:ink_only, file.path, 30, 12).path)
    expect([img.width, img.height]).to all(be < 70)
  end

  it 'thickens a hairline pen stroke so it prints at a visible weight' do
    pad = (Vips::Image.black(464, 180) + 255).copy(interpretation: :b_w)
    line = Vips::Image.black(300, 2) # a 2px stroke, shrunk about 3x onto a signature line
    file = Tempfile.new(['pad', '.png']).tap { |f| pad.insert(line, 80, 90).write_to_file(f.path) }
    img = Vips::Image.new_from_file(service.send(:ink_only, file.path, 100, 28).path)
    printed = service.send(:stroke_px, img[3]) * 100.0 / 300
    expect(printed).to be >= described_class::MIN_STROKE_PT * 0.9
  end

  it 'fills the box with the mark instead of the empty pad' do
    pdf = Prawn::Document.new
    expect(pdf).to receive(:image).with(anything, hash_including(height: be_within(0.01).of(12))).and_call_original
    expect(service.send(:stamp_image, pdf, 100, 500, 30, 12, pad)).to be true
  end

  it 'still stamps a pad with no ink found' do
    blank = "data:image/png;base64,#{Base64.strict_encode64(Vips::Image.black(40, 20, bands: 4).copy(interpretation: :srgb).write_to_buffer('.png'))}"
    expect(service.send(:stamp_image, Prawn::Document.new, 100, 500, 30, 12, blank)).to be true
  end
end
