# frozen_string_literal: true

require 'rails_helper'

# Listings currently hot-link three third-party CDNs. If a manufacturer
# reorganises a URL, every dealer listing pointing at it goes blank.
RSpec.describe Catalog::ImageArchiver do
  let(:uploader) { instance_double(S3UploadService, bucket_name: 'assets', region: 'us-east-1') }
  let(:archiver) { described_class.new(uploader: uploader) }

  let(:photo)  { 'https://api.claytonhomes.com/images/mfg/ext/one.jpg' }
  let(:plan)   { 'https://trove.b-cdn.net/images/plan.png' }

  def image(url, extra = {})
    { 'source_url' => url, 'local_url' => nil, 'alt' => 'exterior' }.merge(extra)
  end

  before do
    allow(uploader).to receive(:list_files).and_return([])
    allow(uploader).to receive(:upload) do |_file, folder:, key:|
      { url: "https://assets.s3.us-east-1.amazonaws.com/#{key}", key: key }
    end
    # Stand in for the network so specs never reach a CDN.
    allow(archiver).to receive(:open_source).and_return(StringIO.new('bytes'))
  end

  describe 'content addressing' do
    # Without this, S3UploadService's random key means every nightly run
    # re-uploads every image to a fresh URL: unbounded storage, and a changed
    # local_url on every vehicle every night.
    it 'derives a stable key from the source URL' do
      expect(archiver.key_for(photo)).to eq(archiver.key_for(photo))
    end

    it 'gives different URLs different keys' do
      expect(archiver.key_for(photo)).not_to eq(archiver.key_for(plan))
    end

    it 'keeps the real extension' do
      expect(archiver.key_for(plan)).to end_with('.png')
    end

    # Manufacturer URLs carry cache-busting queries; a query string must never
    # leak into an S3 key.
    it 'ignores a cache-busting query' do
      expect(archiver.key_for("#{photo}?cid=abc123")).to end_with('.jpg')
      expect(archiver.key_for("#{photo}?cid=abc123")).not_to include('?')
    end

    it 'falls back to .jpg for an unrecognised extension' do
      expect(archiver.key_for('https://cdn.example.com/image')).to end_with('.jpg')
      expect(archiver.key_for('https://cdn.example.com/thing.svg')).to end_with('.jpg')
    end
  end

  describe 'archiving' do
    it 'fills local_url and keeps source_url' do
      out = archiver.archive([image(photo)]).first
      expect(out['local_url']).to include('assets.s3.us-east-1.amazonaws.com')
      expect(out['source_url']).to eq(photo)
    end

    it 'preserves the other fields on the record' do
      out = archiver.archive([image(plan, 'is_floorplan' => true)]).first
      expect(out['is_floorplan']).to be(true)
      expect(out['alt']).to eq('exterior')
    end

    it 'reports what it did' do
      archiver.archive([image(photo), image(plan)])
      expect(archiver.result.archived).to eq(2)
    end
  end

  describe 'not re-uploading what we already hold' do
    it 'reuses an object already in the bucket without downloading' do
      key = archiver.key_for(photo)
      allow(uploader).to receive(:list_files).and_return([key])

      expect(uploader).not_to receive(:upload)
      out = archiver.archive([image(photo)]).first

      expect(out['local_url']).to end_with(key)
      expect(archiver.result.reused).to eq(1)
    end

    # The listing is what makes a re-run cheap; a HEAD per image would be
    # thousands of round trips.
    it 'lists the folder once, not once per image' do
      expect(uploader).to receive(:list_files).once.and_return([])
      archiver.archive([image(photo), image(plan), image("#{photo}?v=2")])
    end

    it 'does not upload the same URL twice within one run' do
      archiver.archive([image(photo), image(photo)])
      expect(archiver.result.archived).to eq(1)
      expect(archiver.result.reused).to eq(1)
    end

    it 'leaves an already-archived record alone' do
      out = archiver.archive([image(photo, 'local_url' => 'https://assets/existing.jpg')]).first
      expect(out['local_url']).to eq('https://assets/existing.jpg')
      expect(archiver.result.skipped).to eq(1)
    end
  end

  # Archiving must never be able to fail a run that otherwise succeeded.
  describe 'failure is survivable' do
    it 'keeps source_url when the download fails' do
      allow(archiver).to receive(:open_source).and_raise(StandardError, 'CDN down')

      out = archiver.archive([image(photo)]).first
      expect(out['local_url']).to be_nil
      expect(out['source_url']).to eq(photo)
      expect(archiver.result.failed).to eq(1)
    end

    it 'keeps going after one bad image' do
      call = 0
      allow(archiver).to receive(:open_source) do
        call += 1
        raise StandardError, 'boom' if call == 1

        StringIO.new('bytes')
      end

      out = archiver.archive([image(photo), image(plan)])
      expect(out.first['local_url']).to be_nil
      expect(out.last['local_url']).to be_present
    end

    # A bucket outage should degrade to "upload everything", not crash.
    it 'survives a failed listing' do
      allow(uploader).to receive(:list_files).and_raise(StandardError, 'S3 unreachable')
      expect { archiver.archive([image(photo)]) }.not_to raise_error
    end

    it 'skips a record with no URL at all' do
      out = archiver.archive([{ 'alt' => 'orphan' }])
      expect(out.first['local_url']).to be_nil
      expect(archiver.result.skipped).to eq(1)
    end
  end
end
