# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WebsiteMedia, type: :model do
  let(:company) { Company.create!(name: "Media-#{SecureRandom.hex(4)}") }

  def media(attrs)
    described_class.new({ company: company, name: 'clip.mp4', file_size: 1 }.merge(attrs))
  end

  describe '#full_url' do
    # The CDN arm used to sit last, and every upload writes both url and s3_key,
    # so the earlier arms always matched and pointing CDN_DOMAIN at a
    # distribution changed nothing at all.
    context 'with CDN_DOMAIN set' do
      around do |example|
        original = ENV['CDN_DOMAIN']
        ENV['CDN_DOMAIN'] = 'cdn.example.com'
        example.run
      ensure
        ENV['CDN_DOMAIN'] = original
      end

      it 'serves a stored key through the CDN' do
        item = media(s3_bucket: 'renterinsight-website-assets-staging',
                     s3_key: 'websites/7/media/clip.mp4',
                     url: 'https://renterinsight-website-assets-staging.s3.us-west-2.amazonaws.com/websites/7/media/clip.mp4')

        expect(item.full_url).to eq('https://cdn.example.com/websites/7/media/clip.mp4')
      end

      it 'serves assets stored before s3_key existed through the CDN too' do
        item = media(s3_bucket: 'renterinsight-website-assets-staging', s3_key: nil,
                     url: 'https://renterinsight-website-assets-staging.s3.us-west-2.amazonaws.com/websites/7/media/old.png')

        expect(item.full_url).to eq('https://cdn.example.com/websites/7/media/old.png')
      end

      # Rewriting somebody else's host onto our distribution would 404.
      it 'leaves a URL that is not ours alone' do
        item = media(s3_key: nil, url: 'https://images.pexels.com/photos/1/x.jpeg')

        expect(item.full_url).to eq('https://images.pexels.com/photos/1/x.jpeg')
      end

      # A distribution has one origin; rows here can name several buckets, and
      # CATALOG_ASSETS_BUCKET exists so catalog imagery does not share the
      # uploads bucket at all.
      it 'leaves an object in a different bucket on its own S3 URL' do
        item = media(s3_bucket: 'dealertide-catalog-assets',
                     s3_key: 'catalog/1/plan.jpg',
                     url: 'https://dealertide-catalog-assets.s3.us-west-2.amazonaws.com/catalog/1/plan.jpg')

        expect(item.full_url).to eq('https://dealertide-catalog-assets.s3.us-west-2.amazonaws.com/catalog/1/plan.jpg')
      end

      it 'recognises the fronted bucket from the URL when the column is empty' do
        item = media(s3_bucket: nil, s3_key: nil,
                     url: 'https://renterinsight-website-assets-staging.s3.us-west-2.amazonaws.com/websites/7/a.png')

        expect(item.full_url).to eq('https://cdn.example.com/websites/7/a.png')
      end
    end

    # The env var is typed by a human copying out of the CloudFront console,
    # where the value on screen is a bare hostname but the habit is to paste a
    # URL. Interpolating that verbatim produced https://https://cdn…//key.
    context 'when CDN_DOMAIN was pasted with a scheme' do
      around do |example|
        original = ENV['CDN_DOMAIN']
        ENV['CDN_DOMAIN'] = 'https://d111111abcdef8.cloudfront.net/'
        example.run
      ensure
        ENV['CDN_DOMAIN'] = original
      end

      it 'still builds one well-formed URL' do
        item = media(s3_key: 'websites/7/media/clip.mp4',
                     url: 'https://renterinsight-website-assets-staging.s3.us-west-2.amazonaws.com/websites/7/media/clip.mp4')

        expect(item.full_url).to eq('https://d111111abcdef8.cloudfront.net/websites/7/media/clip.mp4')
      end
    end

    context 'without CDN_DOMAIN' do
      around do |example|
        original = ENV['CDN_DOMAIN']
        ENV.delete('CDN_DOMAIN')
        example.run
      ensure
        ENV['CDN_DOMAIN'] = original
      end

      it 'keeps serving the public S3 URL, so nothing already published moves' do
        item = media(s3_bucket: 'renterinsight-website-assets-staging',
                     s3_key: 'websites/7/media/clip.mp4',
                     url: 'https://renterinsight-website-assets-staging.s3.us-west-2.amazonaws.com/websites/7/media/clip.mp4')

        expect(item.full_url).to eq('https://renterinsight-website-assets-staging.s3.us-west-2.amazonaws.com/websites/7/media/clip.mp4')
      end
    end
  end

  describe '.max_upload_bytes' do
    it 'gives video the headroom a phone walkthrough actually needs' do
      expect(described_class.max_upload_bytes('video/mp4')).to eq(200.megabytes)
    end

    it 'holds images to something worth sending to a phone' do
      expect(described_class.max_upload_bytes('image/png')).to eq(25.megabytes)
    end

    it 'falls back for a type it does not know' do
      expect(described_class.max_upload_bytes(nil)).to eq(50.megabytes)
    end
  end
end
