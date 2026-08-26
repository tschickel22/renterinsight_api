# frozen_string_literal: true

require 'rails_helper'

# A dealer who posts straight to their Facebook Page, from the phone, had a
# comment inbox that was permanently empty. The sync walked social_posts, a
# post made on Facebook has no row there, so its comments were never asked for
# and nothing on screen said why.
RSpec.describe SyncSocialCommentsJob, 'posts made on the Page itself' do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }

  let!(:integration) do
    FacebookIntegration.create!(company_id: company.id, page_id: 'PAGE-1',
                                page_name: 'DealerTide', page_access_token: 'PAGE-TOKEN',
                                status: 'active')
  end

  let(:native_post) do
    { 'id' => 'PAGE-1_900', 'message' => 'Posted from my phone',
      'created_time' => 2.days.ago.iso8601 }
  end

  let(:comment) do
    { 'id' => 'COMMENT-1', 'message' => 'Do you have this in a 3 bed?',
      'created_time' => 1.day.ago.iso8601,
      'from' => { 'id' => 'VISITOR-9', 'name' => 'Tom Schickel' } }
  end

  before do
    allow(SocialMediaSettingsService).to receive(:for_company)
      .and_return({ 'comment_sync_enabled' => true })
    allow(MetaGraphApi).to receive(:get_page_posts).and_return({ 'data' => [native_post] })
    allow(MetaGraphApi).to receive(:get_post_comments).and_return({ 'data' => [comment] })
  end

  it 'stores the comment that used to be unreachable' do
    described_class.new.perform

    expect(company.social_comments.pluck(:message)).to eq(['Do you have this in a 3 bed?'])
  end

  it 'asks Facebook for that post by id' do
    described_class.new.perform

    expect(MetaGraphApi).to have_received(:get_post_comments)
      .with('PAGE-1_900', 'PAGE-TOKEN', hash_including(:limit))
  end

  # social_comments.social_post_id is NOT NULL, so the row is what makes the
  # comment storable at all.
  it 'gives the Page post a row to hang off' do
    described_class.new.perform

    adopted = company.social_posts.find_by(external_post_id: 'PAGE-1_900')
    expect(adopted).to be_present
    expect(adopted.imported_from_page).to be(true)
    expect(company.social_comments.first.social_post_id).to eq(adopted.id)
  end

  # The Posts tab says "Posts created in DealerTide" and the tile under it
  # should go on meaning that, or adopting posts silently rewrites the number a
  # dealer judges their own output by.
  it 'keeps the adopted post out of the Posts tab' do
    described_class.new.perform

    expect(company.social_posts.active.where(imported_from_page: false).count).to eq(0)
  end

  it 'does not adopt the same post twice' do
    described_class.new.perform
    described_class.new.perform

    expect(company.social_posts.where(external_post_id: 'PAGE-1_900').count).to eq(1)
    expect(company.social_comments.count).to eq(1)
  end

  it 'leaves a post older than the lookback window alone' do
    allow(MetaGraphApi).to receive(:get_page_posts)
      .and_return({ 'data' => [native_post.merge('created_time' => 90.days.ago.iso8601)] })

    described_class.new.perform

    expect(company.social_posts.count).to eq(0)
  end

  # A post we published through DealerTide already has a row. Adopting it again
  # would split its comments across two posts.
  it 'does not duplicate a post we published ourselves' do
    ours = company.social_posts.create!(platform: 'facebook', status: 'published',
                                        caption: 'ours', external_post_id: 'PAGE-1_900',
                                        published_at: 2.days.ago)

    described_class.new.perform

    expect(company.social_posts.where(external_post_id: 'PAGE-1_900').count).to eq(1)
    expect(company.social_comments.first.social_post_id).to eq(ours.id)
  end

  # Losing the Page feed must not cost us the comments on posts we do hold.
  it 'still syncs our own posts when the Page feed cannot be read' do
    ours = company.social_posts.create!(platform: 'facebook', status: 'published',
                                        caption: 'ours', external_post_id: 'OURS-1',
                                        published_at: 2.days.ago)
    allow(MetaGraphApi).to receive(:get_page_posts).and_raise(MetaGraphApi::Error, 'no permission')

    expect { described_class.new.perform }.not_to raise_error
    expect(company.social_comments.first&.social_post_id).to eq(ours.id)
  end
end
