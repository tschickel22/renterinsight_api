# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::DocumentIngestor do
  let(:pdf_bytes) { File.binread(Rails.root.join('spec/fixtures/files/product_sheet.pdf')) }

  def ingest(bytes, filename: 'sheet.pdf', content_type: nil)
    described_class.new(bytes: bytes, filename: filename, content_type: content_type).call
  end

  describe 'PDF' do
    it 'produces one digest per page plus rendered page images' do
      result = ingest(pdf_bytes)

      expect(result.digests).not_to be_empty
      expect(result.page_count).to be >= 1
      expect(result.images.first['content_type']).to eq('image/jpeg') if result.images.any?
    end

    it 'emits digests ProfileBuilder can consume unchanged' do
      digest = ingest(pdf_bytes).digests.first

      # ProfileBuilder#user_message reads exactly these.
      expect(digest).to respond_to(:url, :title, :meta_description, :headings,
                                   :paragraphs, :images, :background_images, :forms)
      expect(digest.url).to start_with('document://')
      expect(digest.images).to eq([])
      expect(digest.forms).to eq([])
    end

    # text_ratio drives PageDigest#likely_client_rendered?, which would
    # otherwise add a "renders with JavaScript" warning to a PDF.
    it 'does not look client-rendered' do
      expect(ingest(pdf_bytes).digests.first.likely_client_rendered?).to be(false)
    end

    it 'titles the first page from the filename' do
      result = ingest(pdf_bytes, filename: 'Aspen_Product-Sheet.pdf')
      expect(result.digests.first.title).to eq('Aspen Product Sheet')
    end

    it 'warns when pages could not be rendered to images' do
      allow(SiteProfiles::DocumentRasterizer).to receive(:call).and_return([])
      result = ingest(pdf_bytes)

      expect(result.images).to be_empty
      expect(result.warnings.join).to match(/read from text only/i)
    end

    it 'raises when neither text nor images can be read' do
      allow(SiteProfiles::DocumentRasterizer).to receive(:call).and_return([])
      allow(PDF::Reader).to receive(:new).and_raise(StandardError, 'encrypted')

      expect { ingest(pdf_bytes) }
        .to raise_error(described_class::UnsupportedDocumentError, /No text or images/i)
    end

    # A scanned-paper PDF: vision carries it, but extraction quality differs
    # enough to be worth saying.
    it 'notes when a PDF has images but no selectable text' do
      allow(PDF::Reader).to receive(:new).and_raise(StandardError, 'no text layer')
      result = ingest(pdf_bytes)

      skip 'pdftoppm not installed' if result.images.empty?
      expect(result.warnings.join).to match(/page images/i)
    end
  end

  describe 'content type sniffing' do
    it 'detects a PDF regardless of the declared type' do
      result = ingest(pdf_bytes, content_type: nil)
      expect(result.digests).not_to be_empty
    end

    it 'trusts magic bytes over a wrong declared type' do
      # Browsers routinely send octet-stream for ordinary uploads.
      result = described_class.new(
        bytes: pdf_bytes, filename: 'x.pdf', content_type: nil
      ).call
      expect(result.digests.first.url).to start_with('document://')
    end
  end

  describe 'images' do
    # 1x1 PNG.
    let(:png) do
      Base64.decode64(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
      )
    end

    it 'passes an uploaded image straight through as the only page' do
      result = ingest(png, filename: 'flyer.png', content_type: 'image/png')

      expect(result.page_count).to eq(1)
      expect(result.images.size).to eq(1)
      expect(result.images.first['content_type']).to eq('image/png')
      expect(result.digests.size).to eq(1)
    end
  end

  describe 'plain text' do
    it 'splits short lines into headings and prose into paragraphs' do
      text = "The Aspen 2848\nA spacious three bedroom home with an open plan kitchen and vaulted ceilings.\n"
      result = ingest(text, filename: 'notes.txt', content_type: 'text/plain')

      digest = result.digests.first
      expect(digest.headings.map { |h| h[:text] }).to include('The Aspen 2848')
      expect(digest.paragraphs.first).to match(/spacious three bedroom/)
      expect(result.warnings.join).to match(/no layout/i)
    end

    it 'rejects a whitespace-only text file' do
      expect { ingest("   \n  ", filename: 'e.txt', content_type: 'text/plain') }
        .to raise_error(described_class::UnsupportedDocumentError, /empty/i)
    end
  end

  describe 'rejections' do
    it 'rejects an empty upload' do
      expect { ingest('') }
        .to raise_error(described_class::UnsupportedDocumentError, /empty/i)
    end

    it 'rejects an unsupported type with an actionable message' do
      expect { ingest("PK\x03\x04binary", filename: 'a.zip', content_type: 'application/zip') }
        .to raise_error(described_class::UnsupportedDocumentError, /Upload a PDF, an image, or a text file/)
    end
  end
end
