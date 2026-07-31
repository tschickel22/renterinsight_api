# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::AssetImporter do
  let(:company) { Company.first || create(:company) }

  let(:record) do
    SiteContentProfile.create!(
      company: company,
      source_url: 'https://dealer.example/',
      status: 'ready',
      profile: {
        'brand' => { 'logo_url' => 'https://dealer.example/img/logo.png' },
        'media' => {
          'logo' => 'https://dealer.example/img/logo.png',
          'hero_images' => ['https://dealer.example/img/hero.jpg', 'https://dealer.example/img/bad.jpg'],
          'gallery' => ['https://dealer.example/img/g1.jpg']
        }
      }
    )
  end

  let(:uploader) { instance_double('S3UploadService') }

  before do
    allow(SiteProfiles::UrlGuard).to receive(:validate!) { |u| [URI.parse(u), []] }
    allow(uploader).to receive(:upload) do |file, **|
      { url: "https://ourbucket.s3.amazonaws.com/site-imports/#{file.original_filename}",
        key: "site-imports/#{file.original_filename}", size: file.size, content_type: file.content_type }
    end
  end

  def stub_image(url, content_type: 'image/jpeg', body: 'binarydata', status: Net::HTTPOK)
    response = instance_double(status.to_s, body: body)
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(status == Net::HTTPOK)
    allow(response).to receive(:[]).with('content-type').and_return(content_type)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(response)
    allow(Net::HTTP).to receive(:new).with(URI.parse(url).host, anything).and_return(http)
  end

  describe 'rehosting' do
    before { stub_image('https://dealer.example/img/hero.jpg') }

    it 'rewrites every image url onto our bucket' do
      result = described_class.new(record, uploader: uploader).call

      urls = [result.profile.dig('media', 'logo')] +
             result.profile.dig('media', 'hero_images') +
             result.profile.dig('media', 'gallery')

      expect(urls).to all(start_with('https://ourbucket.s3.amazonaws.com/'))
      expect(urls.join).not_to include('dealer.example')
    end

    it 'rewrites the brand logo too, not just media' do
      result = described_class.new(record, uploader: uploader).call
      expect(result.profile.dig('brand', 'logo_url')).to start_with('https://ourbucket.s3.amazonaws.com/')
    end

    it 'persists the rewritten profile' do
      described_class.new(record, uploader: uploader).call
      expect(record.reload.profile.dig('media', 'logo')).to include('ourbucket')
    end

    it 'creates a media row per imported asset' do
      expect { described_class.new(record, uploader: uploader).call }
        .to change { WebsiteMedia.where(company_id: company.id).count }.by_at_least(1)
    end

    it 'uploads each distinct url once, however often it appears' do
      described_class.new(record, uploader: uploader).call
      # logo appears in both brand.logo_url and media.logo
      expect(uploader).to have_received(:upload).exactly(4).times
    end
  end

  describe 'refusing bad assets' do
    it 'drops an image rather than leaving a broken link when it will not download' do
      allow(Net::HTTP).to receive(:new).and_raise(Errno::ECONNREFUSED)

      result = described_class.new(record, uploader: uploader).call
      expect(result.profile.dig('media', 'hero_images')).to eq([])
      expect(result.skipped).to be_positive
    end

    it 'refuses anything that is not an allowed image type' do
      stub_image('https://dealer.example/img/hero.jpg', content_type: 'text/html')

      result = described_class.new(record, uploader: uploader).call
      expect(result.profile.dig('media', 'hero_images')).to eq([])
      expect(result.warnings.join).to match(/non-image/i)
    end

    it 'refuses an image that is too large' do
      stub_image('https://dealer.example/img/hero.jpg', body: 'x' * (13 * 1024 * 1024))

      result = described_class.new(record, uploader: uploader).call
      expect(result.warnings.join).to match(/larger than/i)
    end

    # An image URL is attacker-controlled input exactly like a page URL.
    it 'runs image urls through the same SSRF guard as the crawl' do
      allow(SiteProfiles::UrlGuard).to receive(:validate!)
        .and_raise(SiteProfiles::UrlGuard::BlockedUrlError, 'nope')

      result = described_class.new(record, uploader: uploader).call
      expect(result.imported).to eq(0)
      expect(result.warnings.join).to match(/non-public address/i)
      expect(uploader).not_to have_received(:upload)
    end
  end
end
