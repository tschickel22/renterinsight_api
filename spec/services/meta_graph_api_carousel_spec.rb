# frozen_string_literal: true

require 'rails_helper'

# Facebook multi-photo posts: each image is uploaded unpublished for a media id,
# then all of them are attached to one feed post. Same pages_manage_posts
# permission as a single-photo post, so no extra App Review surface.
RSpec.describe MetaGraphApi, '.publish_page_carousel' do
  let(:page_id) { '123' }
  let(:token)   { 'tok' }

  def carousel(urls)
    described_class.publish_page_carousel(
      page_id, token, message: 'Caption', image_urls: urls
    )
  end

  it 'uploads each image unpublished, then attaches them to one feed post' do
    expect(described_class).to receive(:post)
      .with("/#{page_id}/photos", token, url: 'https://x/a.jpg', published: false)
      .and_return({ 'id' => 'm1' })
    expect(described_class).to receive(:post)
      .with("/#{page_id}/photos", token, url: 'https://x/b.jpg', published: false)
      .and_return({ 'id' => 'm2' })

    expect(described_class).to receive(:post).with(
      "/#{page_id}/feed", token,
      message: 'Caption',
      :"attached_media[0]" => '{"media_fbid":"m1"}',
      :"attached_media[1]" => '{"media_fbid":"m2"}'
    ).and_return({ 'id' => 'post_1' })

    expect(carousel(%w[https://x/a.jpg https://x/b.jpg])).to eq({ 'id' => 'post_1' })
  end

  it 'caps at the 10 Facebook will render' do
    urls = (1..14).map { |i| "https://x/#{i}.jpg" }
    allow(described_class).to receive(:post).and_return({ 'id' => 'm' })

    expect(described_class).to receive(:post)
      .with("/#{page_id}/photos", token, hash_including(published: false))
      .exactly(10).times.and_return({ 'id' => 'm' })

    carousel(urls)
  end

  it 'falls back to a native photo post for a single image' do
    expect(described_class).to receive(:post)
      .with("/#{page_id}/photos", token, caption: 'Caption', url: 'https://x/a.jpg')
      .and_return({ 'id' => 'p' })

    carousel(['https://x/a.jpg'])
  end

  # One bad URL shouldn't take the whole post down.
  it 'skips an image that fails to upload and posts the rest' do
    allow(described_class).to receive(:post)
      .with("/#{page_id}/photos", token, url: 'https://x/a.jpg', published: false)
      .and_raise(MetaGraphApi::Error, 'unreachable')
    allow(described_class).to receive(:post)
      .with("/#{page_id}/photos", token, url: 'https://x/b.jpg', published: false)
      .and_return({ 'id' => 'm2' })
    allow(described_class).to receive(:post)
      .with("/#{page_id}/photos", token, url: 'https://x/c.jpg', published: false)
      .and_return({ 'id' => 'm3' })

    expect(described_class).to receive(:post).with(
      "/#{page_id}/feed", token,
      message: 'Caption',
      :"attached_media[0]" => '{"media_fbid":"m2"}',
      :"attached_media[1]" => '{"media_fbid":"m3"}'
    ).and_return({ 'id' => 'post_1' })

    carousel(%w[https://x/a.jpg https://x/b.jpg https://x/c.jpg])
  end

  it 'degrades to a photo post when only one image survives upload' do
    allow(described_class).to receive(:post)
      .with("/#{page_id}/photos", token, url: 'https://x/a.jpg', published: false)
      .and_raise(MetaGraphApi::Error, 'unreachable')
    allow(described_class).to receive(:post)
      .with("/#{page_id}/photos", token, url: 'https://x/b.jpg', published: false)
      .and_return({ 'id' => 'm2' })

    expect(described_class).to receive(:post)
      .with("/#{page_id}/photos", token, hash_including(caption: 'Caption'))
      .and_return({ 'id' => 'p' })

    carousel(%w[https://x/a.jpg https://x/b.jpg])
  end

  it 'returns nil when nothing uploads rather than posting an empty carousel' do
    allow(described_class).to receive(:post).and_raise(MetaGraphApi::Error, 'unreachable')
    expect(carousel(%w[https://x/a.jpg https://x/b.jpg])).to be_nil
  end

  it 'ignores blank entries' do
    expect(described_class).to receive(:post)
      .with("/#{page_id}/photos", token, caption: 'Caption', url: 'https://x/a.jpg')
      .and_return({ 'id' => 'p' })

    carousel(['https://x/a.jpg', '', '  ', nil])
  end
end
