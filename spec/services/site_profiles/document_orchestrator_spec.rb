# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::DocumentOrchestrator do
  let(:company) { Company.create!(name: "Doc-#{SecureRandom.hex(4)}") }
  let(:pdf_bytes) { File.binread(Rails.root.join('spec/fixtures/files/product_sheet.pdf')) }

  let(:record) do
    SiteContentProfile.create!(
      company: company,
      source_kind: 'document',
      source_url: nil,
      document_filename: 'Aspen Product Sheet.pdf',
      document_s3_key: 'site-profiles/uploads/1/aspen.pdf',
      document_content_type: 'application/pdf',
      document_byte_size: pdf_bytes.bytesize,
      status: 'pending'
    )
  end

  # Neither S3 nor Anthropic is reachable from a spec, so both are stubbed at
  # their seams. Everything between them is the real code path.
  let(:downloader) { ->(_key) { pdf_bytes } }

  let(:model_profile) do
    {
      'brand' => { 'name' => 'Summit Park Homes', 'colors' => { 'primary' => '#0d9488' } },
      'contact' => { 'phone' => '(303) 586-4420' },
      'copy' => {
        'hero' => [{ 'headline' => 'The Aspen 2848', 'subhead' => 'Three bedrooms, open plan' }],
        'product' => [{ 'name' => 'The Aspen 2848', 'model_number' => 'A-2848', 'msrp' => '$189,900' }],
        'specs' => [{ 'label' => 'Square Feet', 'value' => '1,344', 'unit' => 'sq ft' }],
        'floorplan' => [{ 'name' => 'Aspen', 'beds' => '3', 'baths' => '2' }]
      }
    }
  end

  def stub_builder(profile: model_profile, warnings: [])
    allow_any_instance_of(SiteProfiles::ProfileBuilder).to receive(:call) do |_instance, **kwargs|
      @builder_kwargs = kwargs
      coerced, = SiteProfiles::ProfileSchema.coerce(profile)
      [coerced, warnings, { model_version: 'claude-test', input_tokens: 10, output_tokens: 20 }]
    end
  end

  before do
    stub_builder
    # No bucket in specs; page image storage is exercised separately.
    allow_any_instance_of(SiteProfiles::DocumentPageMediaImporter).to receive(:call).and_return([])
  end

  def run
    described_class.new(record, downloader: downloader).call
  end

  # The download adapter is normally stubbed, which is exactly why a real
  # upload failed while every spec passed: S3 returns bytes tagged UTF-8, a PDF
  # is not valid UTF-8, and the first string operation downstream raised.
  describe SiteProfiles::DocumentOrchestrator::S3DownloadAdapter do
    it 'tags downloaded bytes as binary' do
      utf8_tagged = pdf_bytes.dup.force_encoding(Encoding::UTF_8)
      expect(utf8_tagged.valid_encoding?).to be(false)
      allow_any_instance_of(S3UploadService).to receive(:download).and_return(utf8_tagged)

      bytes = described_class.new.call('some/key.pdf')

      expect(bytes.encoding).to eq(Encoding::BINARY)
      expect(bytes.valid_encoding?).to be(true)
      expect { bytes.squish }.not_to raise_error
    end

    it 'passes nil through for a missing key' do
      expect(described_class.new.call(nil)).to be_nil
    end
  end

  it 'drives the record to ready with a coerced profile' do
    run
    record.reload

    expect(record.status).to eq('ready')
    expect(record.schema_version).to eq(SiteProfiles::ProfileSchema::VERSION)
    expect(record.profile.dig('copy', 'product', 0, 'name')).to eq('The Aspen 2848')
    expect(record.profile.dig('copy', 'specs', 0, 'value')).to eq('1,344')
    expect(record.model_version).to eq('claude-test')
  end

  it 'passes the rendered page images to the builder' do
    run

    expect(@builder_kwargs[:images]).to be_present
    expect(@builder_kwargs[:images].first['content_type']).to eq('image/jpeg')
    expect(@builder_kwargs[:source_url]).to eq('document://Aspen Product Sheet.pdf')
  end

  it 'records how many pages were rendered' do
    run
    expect(record.reload.rasterized_page_count).to be >= 1
  end

  it 'writes a document-shaped report' do
    run
    report = record.reload.report

    expect(report['source_kind']).to eq('document')
    expect(report['document_filename']).to eq('Aspen Product Sheet.pdf')
    expect(report['page_count']).to be >= 1
    expect(report['pages_scanned'].first).to start_with('document://')
  end

  # A product sheet that yields no product content otherwise looks identical to
  # a sparse one, and the difference decides whether the admin re-uploads.
  it 'warns when no product content was found' do
    stub_builder(profile: { 'copy' => { 'hero' => [{ 'headline' => 'Welcome' }] } })
    run

    expect(record.reload.report['warnings'].join).to match(/No product, spec or floor plan/i)
  end

  it 'does not warn about product content when the document had some' do
    run
    expect(record.reload.report['warnings'].join).not_to match(/No product, spec/i)
  end

  it 'carries ingestor warnings into the report' do
    allow(SiteProfiles::DocumentRasterizer).to receive(:call).and_return([])
    run

    expect(record.reload.report['warnings'].join).to match(/text only/i)
  end

  describe 'failures' do
    it 'marks the record failed when the document is gone from S3' do
      orchestrator = described_class.new(record, downloader: ->(_k) { nil })

      expect { orchestrator.call }.to raise_error(described_class::DocumentUnavailableError)
      expect(record.reload.status).to eq('failed')
      expect(record.error_message).to match(/could not be retrieved/i)
    end

    it 'marks the record failed on an unsupported document' do
      orchestrator = described_class.new(record, downloader: ->(_k) { "PK\x03\x04zip" })
      record.update!(document_content_type: 'application/zip')

      expect { orchestrator.call }.to raise_error(SiteProfiles::DocumentIngestor::UnsupportedDocumentError)
      expect(record.reload.status).to eq('failed')
    end

    # The scan succeeded; failing to store page images must not throw it away.
    it 'keeps a ready profile when page image storage fails' do
      allow_any_instance_of(SiteProfiles::DocumentPageMediaImporter)
        .to receive(:call).and_raise(StandardError, 'no bucket')

      run
      record.reload

      expect(record.status).to eq('ready')
      expect(record.report['warnings'].join).to match(/could not be stored/i)
    end
  end

  describe 'page image storage' do
    it 'appends stored page URLs to the profile media' do
      allow_any_instance_of(SiteProfiles::DocumentPageMediaImporter)
        .to receive(:call).and_return(['https://cdn.example.com/page-1.jpg'])

      run

      expect(record.reload.profile.dig('media', 'gallery')).to include('https://cdn.example.com/page-1.jpg')
      expect(record.profile.dig('media', 'hero_images')).to include('https://cdn.example.com/page-1.jpg')
    end
  end

  describe 'job dispatch' do
    it 'routes document profiles to this orchestrator, not the crawler' do
      expect(SiteProfiles::DocumentOrchestrator).to receive(:new).with(record).and_call_original
      expect(SiteProfiles::Orchestrator).not_to receive(:new)

      allow_any_instance_of(described_class).to receive(:call).and_return(record)
      SiteProfileScanJob.new.perform(record.id)
    end

    it 'routes url profiles to the crawler' do
      crawl = SiteContentProfile.create!(
        company: company, source_kind: 'url', source_url: 'https://example.com', status: 'pending'
      )
      fake = instance_double(SiteProfiles::Orchestrator, call: crawl)
      expect(SiteProfiles::Orchestrator).to receive(:new).with(crawl).and_return(fake)

      SiteProfileScanJob.new.perform(crawl.id)
    end
  end
end
