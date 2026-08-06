# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::DocumentRasterizer do
  let(:pdf_bytes) { File.binread(Rails.root.join('spec/fixtures/files/product_sheet.pdf')) }

  before { described_class.reset_availability! }
  after  { described_class.reset_availability! }

  describe '.call' do
    it 'renders PDF pages as base64 JPEG attachments' do
      skip 'pdftoppm not installed' unless described_class.available?

      pages = described_class.call(pdf_bytes)

      expect(pages).not_to be_empty
      first = pages.first
      expect(first['content_type']).to eq('image/jpeg')
      expect(first['page']).to eq(1)
      expect(first['data_base64']).to be_present

      # Actually decodes to a JPEG (magic bytes FF D8 FF), rather than merely
      # being a non-empty string.
      raw = Base64.decode64(first['data_base64'])
      expect(raw[0, 3].unpack('C*')).to eq([0xFF, 0xD8, 0xFF])
    end

    it 'returns pages in page order' do
      skip 'pdftoppm not installed' unless described_class.available?

      pages = described_class.call(pdf_bytes)
      expect(pages.map { |p| p['page'] }).to eq(pages.map { |p| p['page'] }.sort)
    end

    it 'honours the page cap' do
      skip 'pdftoppm not installed' unless described_class.available?

      expect(described_class.call(pdf_bytes, max_pages: 1).size).to be <= 1
    end

    # Every failure mode returns [] so the text-only path still produces a
    # profile. A thin profile beats a failed scan.
    it 'returns [] for blank input' do
      expect(described_class.call(nil)).to eq([])
      expect(described_class.call('')).to eq([])
    end

    it 'returns [] for bytes that are not a PDF' do
      expect(described_class.call('this is plainly not a pdf')).to eq([])
    end

    it 'returns [] rather than raising on a corrupt PDF' do
      corrupt = "%PDF-1.4\n#{SecureRandom.bytes(512)}"
      expect { described_class.call(corrupt) }.not_to raise_error
      expect(described_class.call(corrupt)).to eq([])
    end

    it 'returns [] when pdftoppm is unavailable' do
      allow(described_class).to receive(:available?).and_return(false)
      expect(described_class.call(pdf_bytes)).to eq([])
    end
  end
end
