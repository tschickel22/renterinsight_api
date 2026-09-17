# frozen_string_literal: true

require 'rails_helper'

# Regression cover for the 500 that took the AI post generator down on staging and
# production on 2026-08-26. past_examples returns example_payload hashes, but the
# dedup added in 10899e43 called .id on them, so any company that had a published
# post to use as a style example crashed with NoMethodError before Claude was called.
RSpec.describe SocialPostGeneratorService do
  let(:company) { create(:company) }

  def published_post(caption:, intent: 'feature_spotlight', platform: 'facebook')
    SocialPost.create!(
      company_id: company.id, status: 'published', caption: caption,
      intent_category: intent, platform: platform, published_at: 1.day.ago
    )
  end

  describe '.build_context' do
    it 'excludes the do-not-repeat posts from the style examples' do
      recent = published_post(caption: 'Work Queue is now live')
      older  = published_post(caption: 'Meet the team behind the build')
      allow(described_class).to receive(:recent_posts).and_return([recent])

      ctx = described_class.send(
        :build_context,
        company: company, vehicle: nil, user: nil, intent_category: 'feature_spotlight',
        post_type: 'company_page', platform: 'facebook', tone: 'friendly'
      )

      captions = ctx[:past_examples].map { |e| e[:caption] }
      expect(captions).to include(older.caption)
      expect(captions).not_to include(recent.caption)
    end
  end

  # The context is saved onto every generated post. Keeping whole recent post
  # records in it made each post carry all of its predecessors' contexts, which
  # doubled in size every post until it crashed Postgres and filled the
  # production disk on 2026-09-17.
  describe 'recent posts in the saved context' do
    def context
      described_class.send(
        :build_context,
        company: company, vehicle: nil, user: nil, intent_category: 'feature_spotlight',
        post_type: 'company_page', platform: 'facebook', tone: 'friendly'
      )
    end

    it 'keeps a short summary of each recent post, not the record' do
      published_post(caption: 'Work Queue is now live in DealerTide')

      summary = context[:recent_posts].first

      expect(summary).to be_a(Hash)
      expect(summary.keys).to contain_exactly(:id, :intent_category, :posted_on, :opening)
      expect(summary[:opening]).to eq('Work Queue is now live in DealerTide')
    end

    it 'does not copy a recent post\'s own saved context forward' do
      earlier = published_post(caption: 'An earlier post')
      earlier.update_columns(generation_context: { 'recent_posts' => [{ 'caption' => 'NESTED-MARKER ' * 5_000 }] })

      saved = context.to_json

      expect(saved).not_to include('NESTED-MARKER')
      expect(saved.bytesize).to be < 20_000
    end

    it 'formats a context read back from the database the same as a fresh one' do
      published_post(caption: 'Already said this')
      fresh = context
      read_back = JSON.parse(fresh.to_json).deep_symbolize_keys
      read_back[:recent_posts] = JSON.parse(fresh[:recent_posts].to_json)

      expect(described_class.send(:format_recent_posts, read_back[:recent_posts]))
        .to eq(described_class.send(:format_recent_posts, fresh[:recent_posts]))
    end
  end

  describe '.past_examples' do
    it 'backfills to the limit instead of shrinking when ids are excluded' do
      excluded = published_post(caption: 'Excluded post')
      kept     = published_post(caption: 'Kept post')

      result = described_class.send(
        :past_examples,
        company: company, intent_category: 'feature_spotlight',
        platform: 'facebook', exclude_ids: [excluded.id]
      )

      expect(result.map { |e| e[:caption] }).to eq([kept.caption])
    end
  end

  describe '.build_user_prompt' do
    # The exact shape that crashed: recent_posts are AR records, past_examples are hashes.
    it 'does not call .id on the example payload hashes' do
      recent = published_post(caption: 'Already said this')
      ctx = described_class.send(
        :build_context,
        company: company, vehicle: nil, user: nil, intent_category: 'feature_spotlight',
        post_type: 'company_page', platform: 'facebook', tone: 'friendly'
      )
      ctx[:recent_posts]  = [recent]
      ctx[:past_examples] = [described_class.send(:example_payload, published_post(caption: 'Style reference'))]

      expect { described_class.send(:build_user_prompt, ctx) }.not_to raise_error
      expect(described_class.send(:build_user_prompt, ctx)).to include('Style reference')
    end
  end
end
