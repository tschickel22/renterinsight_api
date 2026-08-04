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
    # A fresh IO per call — the archiver reads each one to completion.
    allow(archiver).to receive(:open_source) { StringIO.new('x' * 50_000) }
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

        StringIO.new('x' * 50_000)
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

  # The archived URL is written into every vehicle row, so a wrong bucket is not
  # something a later env change can undo. In production the catalog bucket must
  # therefore be named explicitly rather than inherited from AWS_S3_BUCKET, which
  # deliberately still points at the shared website-assets bucket.
  describe 'production bucket guard' do
    around do |example|
      original = ENV.fetch(described_class::ENV_BUCKET, nil)
      example.run
      ENV[described_class::ENV_BUCKET] = original
    end

    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it 'refuses to archive when CATALOG_ASSETS_BUCKET is unset' do
      ENV[described_class::ENV_BUCKET] = nil
      allow(uploader).to receive(:bucket_name).and_return('renterinsight-website-assets-staging')

      expect(uploader).not_to receive(:upload)
      out = described_class.new(uploader: uploader).archive([image(photo)])

      expect(out.first['local_url']).to be_nil
      expect(out.first['source_url']).to eq(photo)
    end

    # The old guard inferred intent from the name, so any bucket not containing
    # "staging" passed — including the shared uploads bucket.
    it 'refuses even when the fallback bucket name looks innocuous' do
      ENV[described_class::ENV_BUCKET] = nil
      allow(uploader).to receive(:bucket_name).and_return('ri-uploads-production')

      expect(uploader).not_to receive(:upload)
      expect(described_class.new(uploader: uploader).archive([image(photo)]).first['local_url'])
        .to be_nil
    end

    it 'still refuses when the named catalog bucket looks like a staging one' do
      ENV[described_class::ENV_BUCKET] = 'dt-catalog-assets-staging'
      allow(uploader).to receive(:bucket_name).and_return('dt-catalog-assets-staging')

      expect(uploader).not_to receive(:upload)
      expect(described_class.new(uploader: uploader).archive([image(photo)]).first['local_url'])
        .to be_nil
    end

    it 'archives when the production catalog bucket is named explicitly' do
      ENV[described_class::ENV_BUCKET] = 'dt-catalog-assets-production'
      allow(uploader).to receive(:bucket_name).and_return('dt-catalog-assets-production')

      arch = described_class.new(uploader: uploader)
      allow(arch).to receive(:open_source) { StringIO.new('x' * 50_000) }

      expect(arch.archive([image(photo)]).first['local_url']).to be_present
    end
  end

  # Staging runs RAILS_ENV=staging, so the guard must not fire there — that is
  # what lets a rehearsal use the shared website-assets bucket.
  it 'does not block a staging bucket outside production' do
    allow(uploader).to receive(:bucket_name).and_return('renterinsight-website-assets-staging')
    expect(archiver.archive([image(photo)]).first['local_url']).to be_present
  end

  # A source that enables archiving without naming a delay used to get ZERO,
  # not the documented 1s: every caller passed config['image_crawl_delay'].to_i
  # and nil.to_i is 0, so the keyword default never fired. That is how a Kabco
  # run fired ~1,100 requests as fast as the network allowed and was 429'd.
  describe '.resolve_delay' do
    it 'treats a missing delay as the polite default, not zero' do
      expect(described_class.resolve_delay(nil)).to eq described_class::DEFAULT_DELAY
    end

    it 'treats the nil.to_i result that caused the bug as unset' do
      expect(described_class.resolve_delay(nil.to_i)).to eq described_class::DEFAULT_DELAY
    end

    # Zero is not an escape hatch: it is the one setting already shown to get us
    # rate-limited off a manufacturer's site.
    it 'refuses an explicit zero' do
      expect(described_class.resolve_delay(0)).to eq described_class::DEFAULT_DELAY
    end

    it 'honours a real delay, including a string from JSONB config' do
      expect(described_class.resolve_delay(5)).to eq 5
      expect(described_class.resolve_delay('5')).to eq 5
    end

    it 'applies through the constructor' do
      expect(described_class.new(uploader: uploader).instance_variable_get(:@crawl_delay))
        .to eq described_class::DEFAULT_DELAY
    end
  end

  # Customer uploads and document conversions run off AWS_S3_BUCKET and work
  # today; turning catalog archiving on must not move them. So the archiver
  # takes its bucket from CATALOG_ASSETS_BUCKET and every other upload path is
  # left pointing wherever it already points.
  describe 'bucket selection' do
    around do |example|
      original = ENV.fetch(described_class::ENV_BUCKET, nil)
      example.run
      ENV[described_class::ENV_BUCKET] = original
    end

    it 'uses CATALOG_ASSETS_BUCKET when set' do
      ENV[described_class::ENV_BUCKET] = 'dt-catalog-assets-production'
      expect(S3UploadService).to receive(:new).with(bucket: 'dt-catalog-assets-production')
                                              .and_return(uploader)
      described_class.new
    end

    it 'falls back to the service default when unset, changing nothing' do
      ENV[described_class::ENV_BUCKET] = nil
      expect(S3UploadService).to receive(:new).with(bucket: nil).and_return(uploader)
      described_class.new
    end

    it 'leaves other upload paths on AWS_S3_BUCKET' do
      ENV[described_class::ENV_BUCKET] = 'dt-catalog-assets-production'
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('AWS_S3_BUCKET').and_return('renterinsight-website-assets-staging')
      expect(S3UploadService.new.bucket_name).to eq 'renterinsight-website-assets-staging'
    end
  end

  # Manufacturer sites answer 200 with a placeholder rather than 404 when an
  # image is missing. Kabco returned 348-byte PNGs for two of the first three
  # we archived, alongside a genuine 698 KB one.
  describe 'placeholder responses' do
    it 'does not archive an implausibly small response' do
      allow(archiver).to receive(:open_source) { StringIO.new('x' * 348) }

      out = archiver.archive([image(photo)]).first
      expect(out['local_url']).to be_nil
      expect(archiver.result.failed).to eq(1)
    end

    # Freezing an error is worse than hot-linking: the origin might serve the
    # real file on a later attempt, and it can only do that if we kept the URL.
    it 'keeps source_url so the next run can retry' do
      allow(archiver).to receive(:open_source) { StringIO.new('x' * 348) }

      expect(archiver.archive([image(photo)]).first['source_url']).to eq(photo)
    end

    it 'still archives a genuine image' do
      allow(archiver).to receive(:open_source) { StringIO.new('x' * 698_116) }
      expect(archiver.archive([image(photo)]).first['local_url']).to be_present
    end
  end

  # A full Kabco run with no delay fired ~1,100 requests at their WordPress
  # site and was rate-limited into the ground: 184 archived, 839 refused. It
  # kept going for all 839 after the first refusal.
  describe 'backing off when a host refuses' do
    def too_many_requests
      OpenURI::HTTPError.new('429 Too Many Requests', StringIO.new)
    end

    it 'stops archiving once a host refuses repeatedly' do
      allow(archiver).to receive(:open_source).and_raise(too_many_requests)

      urls = (1..20).map { |i| image("https://kabcobuilders.com/wp-content/uploads/#{i}.jpg") }
      archiver.archive(urls)

      expect(archiver.result.rate_limited).to be(true)
      # Three strikes, then it stops trying rather than grinding through the rest.
      expect(archiver.result.failed).to eq(described_class::RATE_LIMIT_TRIP)
      expect(archiver.result.skipped).to eq(20 - described_class::RATE_LIMIT_TRIP)
    end

    it 'leaves every source_url intact so nothing is lost but time' do
      allow(archiver).to receive(:open_source).and_raise(too_many_requests)

      urls = (1..10).map { |i| image("https://kabcobuilders.com/#{i}.jpg") }
      out = archiver.archive(urls)

      expect(out.map { |i| i['local_url'] }).to all(be_nil)
      expect(out.map { |i| i['source_url'] }).to eq(urls.map { |i| i['source_url'] })
    end

    it 'does not trip on unrelated failures' do
      allow(archiver).to receive(:open_source).and_raise(StandardError, 'connection reset')

      archiver.archive((1..10).map { |i| image("https://kabcobuilders.com/#{i}.jpg") })
      expect(archiver.result.rate_limited).to be(false)
      expect(archiver.result.failed).to eq(10)
    end

    it 'defaults to a real delay rather than hammering a marketing site' do
      expect(described_class::DEFAULT_DELAY).to be > 0
    end
  end
end
