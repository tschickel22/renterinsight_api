# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::Providers::Gemini do
  let(:spec) { { provider: 'gemini', model: 'gemini-test-image' } }
  let(:photo) { (Vips::Image.black(1600, 972, bands: 3) + 120).cast(:uchar) } # 1.65: between 3:2 and 16:9

  def reply(code, width: 1600, height: 900)
    png = (Vips::Image.black(width, height, bands: 3) + 200).cast(:uchar).pngsave_buffer
    body = { 'candidates' => [{ 'content' => { 'parts' => [{ 'inlineData' => { 'data' => Base64.strict_encode64(png), 'mimeType' => 'image/png' } }] } }],
             'usageMetadata' => { 'promptTokenCount' => 10, 'candidatesTokenCount' => 20 } }
    instance_double(HTTParty::Response, code: code, parsed_response: code == 200 ? body : { 'error' => { 'message' => 'Internal error encountered.' } }, body: '')
  end

  before do
    allow(described_class).to receive(:resolve).and_return('gemini-test-image')
    allow(described_class).to receive(:headers).and_return({})
  end

  it 'pads a photo between shapes out to the nearest one, crops the drawing back, and retries a server error' do
    sent = []
    responses = [reply(500), reply(200)]
    allow(HTTParty).to receive(:post) { |_, opts| sent << JSON.parse(opts[:body]); responses.shift }

    result = described_class.edit(spec, { bytes: photo.jpegsave_buffer, mime: 'image/jpeg' }, 'paint', aspect: 1600 / 972.0)

    expect(sent.size).to eq(2)
    expect(sent.last.dig('generationConfig', 'imageConfig', 'aspectRatio')).to eq('16:9')
    padded = Vips::Image.new_from_buffer(Base64.decode64(sent.last.dig('contents', 0, 'parts', 1, 'inline_data', 'data')), '')
    expect(padded.width.to_f / padded.height).to be_within(0.01).of(16 / 9.0)
    drawn = Vips::Image.new_from_buffer(result[:bytes], '')
    expect(drawn.width.to_f / drawn.height).to be_within(0.02).of(1600 / 972.0)
    expect(Truebuild::Trueview.reframed_by(result, 1600 / 972.0)).to be <= Truebuild::Trueview::FRAMING_TOLERANCE
  end

  it 'sends a photo already in a supported shape as it is' do
    sent = []
    allow(HTTParty).to receive(:post) { |_, opts| sent << JSON.parse(opts[:body]); reply(200, width: 1500, height: 1000) }
    three_two = (Vips::Image.black(1500, 1000, bands: 3) + 90).cast(:uchar).jpegsave_buffer
    described_class.edit(spec, { bytes: three_two, mime: 'image/jpeg' }, 'paint', aspect: 1.5)
    expect(Base64.decode64(sent.last.dig('contents', 0, 'parts', 1, 'inline_data', 'data'))).to eq(three_two)
  end
end
