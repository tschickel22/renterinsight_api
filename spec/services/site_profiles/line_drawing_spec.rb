# frozen_string_literal: true

require 'rails_helper'
require 'vips'

RSpec.describe SiteProfiles::LineDrawing do
  # White paper with black walls, like a floor plan.
  def floor_plan_png
    img = (Vips::Image.black(400, 300) + 255).cast(:uchar)
    img = img.draw_rect(0, 20, 20, 360, 4, fill: true)
    img = img.draw_rect(0, 20, 20, 4, 260, fill: true)
    img = img.draw_rect(0, 200, 20, 4, 200, fill: true)
    img.bandjoin([img, img]).copy(interpretation: :srgb).pngsave_buffer
  end

  # A colourful image: sky, siding, grass.
  def photo_png
    xy = Vips::Image.xyz(400, 300)
    x, y = xy.bandsplit
    img = (x * 0.5).bandjoin([y * 0.7 + 40, Vips::Image.black(400, 300) + 120]).cast(:uchar)
    img.copy(interpretation: :srgb).pngsave_buffer
  end

  def grey_photo_png
    xy = Vips::Image.xyz(400, 300)
    x, = xy.bandsplit
    g = (x * 0.4 + 20).cast(:uchar)
    g.bandjoin([g, g]).copy(interpretation: :srgb).pngsave_buffer
  end

  it 'spots a floor plan' do
    expect(described_class.line_drawing?(floor_plan_png)).to be(true)
  end

  it 'keeps a photograph' do
    expect(described_class.line_drawing?(photo_png)).to be(false)
  end

  it 'keeps a black and white photograph, which has no colour but is not mostly white' do
    expect(described_class.line_drawing?(grey_photo_png)).to be(false)
  end

  it 'answers no for bytes it cannot read' do
    expect(described_class.line_drawing?('not an image')).to be(false)
  end
end
