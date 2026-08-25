# frozen_string_literal: true

require 'rails_helper'

# A schedule rotates through a fixed set of intents, so the same one comes round
# every cycle. Nothing told the generator what it had already written, and the
# one thing it WAS shown from this company was a style example for that very
# intent — the post it was about to duplicate. The result was a near-twin every
# cycle: "Just shipped: Work Queue is now live in DealerTide" went out on the
# 16th and again, barely reworded, on the 24th.
RSpec.describe SocialPostGeneratorService, 'not repeating itself' do
  let(:company) { Company.create!(name: "Soc-#{SecureRandom.hex(3)}", industry: 'manufactured_housing') }

  def post(caption:, intent:, status: 'published', at: 1.day.ago)
    SocialPost.create!(company_id: company.id, caption: caption, intent_category: intent,
                       platform: 'facebook', post_type: 'company_page', status: status,
                       published_at: (status == 'published' ? at : nil),
                       created_at: at, updated_at: at)
  end

  def recent = described_class.send(:recent_posts, company: company)

  describe 'what it treats as already said' do
    it 'remembers a published post' do
      post(caption: 'Just shipped: Work Queue is now live.', intent: 'new_release')

      expect(recent.map(&:caption)).to include('Just shipped: Work Queue is now live.')
    end

    # A queued draft publishes later. Treating only published posts as said
    # would let a run duplicate one that has not gone out yet.
    it 'remembers a draft that has not gone out' do
      post(caption: 'Draft about the work queue.', intent: 'new_release', status: 'draft')

      expect(recent.map(&:caption)).to include('Draft about the work queue.')
    end

    it 'remembers across intents, not just the one being written' do
      post(caption: 'A thought leadership take.', intent: 'thought_leadership')
      post(caption: 'A customer win.', intent: 'customer_win')

      expect(recent.size).to eq(2)
    end

    it 'keeps the newest first, so a full rotation is covered' do
      post(caption: 'older', intent: 'new_release', at: 10.days.ago)
      post(caption: 'newer', intent: 'new_release', at: 1.day.ago)

      expect(recent.first.caption).to eq('newer')
    end

    it 'ignores a deleted post' do
      p = post(caption: 'deleted one', intent: 'new_release')
      p.update_columns(is_deleted: true)

      expect(recent.map(&:caption)).not_to include('deleted one')
    end
  end

  describe 'the prompt' do
    # Built the way generate() builds it, so the assertions describe the prompt
    # the model actually receives rather than a hand-rolled approximation.
    let(:ctx) do
      described_class.send(
        :build_context,
        company: company, vehicle: nil, user: nil,
        intent_category: 'new_release', post_type: 'company_page',
        platform: 'facebook', tone: 'friendly',
        profile: SocialPostIntentCatalog.for_company(company)
      ).merge(
        recent_posts: [post(caption: 'Just shipped: Work Queue is now live.', intent: 'new_release')],
        past_examples: []
      )
    end

    it 'tells the model what not to repeat' do
      prompt = described_class.send(:build_user_prompt, ctx)

      expect(prompt).to include('ALREADY POSTED')
      expect(prompt).to include('Just shipped: Work Queue is now live.')
    end

    # The trouble was that the best-performing post for an intent was also the
    # most recent, so "match the voice" handed over the exact post to avoid.
    it 'does not also offer that post as the style to imitate' do
      twin = ctx[:recent_posts].first
      prompt = described_class.send(:build_user_prompt, ctx.merge(past_examples: [twin]))

      expect(prompt).to include('ALREADY POSTED')
      expect(prompt).not_to include('style reference only')
    end
  end
end
