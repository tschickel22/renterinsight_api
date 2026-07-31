# frozen_string_literal: true

require 'rails_helper'

# Facebook has three different endpoints depending on what the post carries, and
# they can't be combined — a video post cannot also hold photos. This pins which
# one each shape routes to.
RSpec.describe PublishSocialPostJob, 'media routing' do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let!(:integration) do
    company.facebook_integrations.create!(
      page_id: 'page-1', page_name: 'P', page_access_token: 'TOK',
      status: 'active', is_deleted: false
    )
  end

  def post_with(**attrs)
    company.social_posts.create!(
      platform: 'facebook', post_type: 'company_page', status: 'approved',
      caption: 'Caption', **attrs
    )
  end

  def publish(post)
    described_class.new.send(:publish_via_meta, post, integration)
  end

  it 'sends a video post to the videos endpoint' do
    post = post_with(video_url: 'https://x/clip.mp4')

    expect(MetaGraphApi).to receive(:publish_page_video)
      .with('page-1', 'TOK', hash_including(video_url: 'https://x/clip.mp4'))
      .and_return({ 'id' => 'v1' })

    publish(post)
  end

  # Facebook rejects a post carrying both, so one has to win outright rather
  # than half-publishing.
  it 'prefers the video when images are also attached' do
    post = post_with(video_url: 'https://x/clip.mp4', image_urls: %w[https://x/a.jpg https://x/b.jpg])

    expect(MetaGraphApi).to receive(:publish_page_video).and_return({ 'id' => 'v1' })
    expect(MetaGraphApi).not_to receive(:publish_page_carousel)
    expect(MetaGraphApi).not_to receive(:publish_page_post)

    publish(post)
  end

  it 'still routes multiple images to a carousel when there is no video' do
    post = post_with(image_urls: %w[https://x/a.jpg https://x/b.jpg])

    expect(MetaGraphApi).to receive(:publish_page_carousel)
      .with('page-1', 'TOK', hash_including(image_urls: %w[https://x/a.jpg https://x/b.jpg]))
      .and_return({ 'id' => 'p1' })

    publish(post)
  end

  it 'still routes a single image to a photo post' do
    post = post_with(image_urls: ['https://x/a.jpg'])

    expect(MetaGraphApi).to receive(:publish_page_post)
      .with('page-1', 'TOK', hash_including(photo_url: 'https://x/a.jpg'))
      .and_return({ 'id' => 'p1' })

    publish(post)
  end

  it 'treats a blank video_url as no video' do
    post = post_with(video_url: '', image_urls: ['https://x/a.jpg'])

    expect(MetaGraphApi).to receive(:publish_page_post).and_return({ 'id' => 'p1' })
    publish(post)
  end

  # Reels is a separate container flow — dropping the video and posting a bare
  # caption would be worse than refusing.
  it 'refuses an Instagram video rather than silently posting text' do
    post = post_with(platform: 'instagram', video_url: 'https://x/clip.mp4')

    expect { publish(post) }
      .to raise_error(MetaGraphApi::Error, /Instagram video posting is not supported/)
  end
end

RSpec.describe MetaGraphApi, '.publish_page_video' do
  it 'posts to /videos with file_url and description' do
    expect(described_class).to receive(:post).with(
      '/page-1/videos', 'TOK',
      file_url: 'https://x/clip.mp4', description: 'Caption'
    ).and_return({ 'id' => 'v1' })

    described_class.publish_page_video(
      'page-1', 'TOK', message: 'Caption', video_url: 'https://x/clip.mp4'
    )
  end

  it 'includes a title when given one' do
    expect(described_class).to receive(:post).with(
      '/page-1/videos', 'TOK',
      file_url: 'https://x/clip.mp4', description: 'Caption', title: 'New Arrival'
    ).and_return({ 'id' => 'v1' })

    described_class.publish_page_video(
      'page-1', 'TOK', message: 'Caption', video_url: 'https://x/clip.mp4', title: 'New Arrival'
    )
  end
end
