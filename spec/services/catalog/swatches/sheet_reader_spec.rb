# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::Swatches::SheetReader do
  # A white page with two solid samples, one white sample drawn as a frame,
  # a caption and a thin heading bar.
  let(:page) do
    img = (Vips::Image.black(1000, 600, bands: 3) + 255).cast(:uchar)
    img = img.draw_rect([104, 97, 85], 50, 50, 200, 150, fill: true)
    img = img.draw_rect([46, 45, 41], 300, 50, 200, 150, fill: true)
    img = img.draw_rect([200, 200, 200], 550, 50, 200, 150)
    img = img.draw_rect([20, 60, 120], 50, 20, 700, 6, fill: true)
    img.draw_rect([0, 0, 0], 60, 220, 14, 10, fill: true)
  end

  it 'finds solid and outlined samples and nothing else' do
    boxes = described_class.new('', filename: 'x.png').find_boxes(page)
    expect(boxes).to eq([[50, 50, 200, 150], [300, 50, 200, 150], [550, 50, 200, 150]])
  end

  it 'names the numbered samples through Claude and cuts them from the page' do
    client = class_double(Catalog::PriceBooks::ClaudeClient)
    allow(client).to receive(:call).and_return(input: {
      'swatches' => [{ 'id' => 1, 'set' => 'Cabinets', 'name' => 'Timberwolf' }, { 'id' => 2, 'set' => 'Countertops', 'name' => 'Lisola' },
                     { 'id' => 3, 'set' => 'Tile', 'name' => 'Catch Ice' }],
      'missed' => []
    }, input_tokens: 2000, output_tokens: 300)
    result = described_class.new(page.pngsave_buffer, filename: 'sheet.png', client: client).call
    expect(result[:swatches].map { |s| [s[:name], s[:hex]] }).to eq([%w[Timberwolf #686155], %w[Lisola #2e2d29], ['Catch Ice', '#ffffff']])
    expect(result[:cost_usd]).to be > 0
  end
end
