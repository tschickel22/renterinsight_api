# frozen_string_literal: true

require 'rails_helper'

# Help said deals could not be deleted (staging, 2026-11-24): no article
# covered the Delete button. This one does, and search finds it.
RSpec.describe 'Delete a deal article' do
  before do
    Knowledge::Module.find_by(key: 'deals') || Knowledge::Module.create!(key: 'deals', name: 'Deals')
    Guide::ArticleLoader.load!(Rails.root.join('db/guide/deal_delete_article.yml'))
  end

  it 'loads, published, and is what help search finds' do
    article = Knowledge::Article.find_by!(slug: 'delete-a-deal')
    expect(article.is_published).to be(true)
    expect(article.content).not_to match(/[–—]/)
    expect(Guide::HelpSearch.call('how do I delete a deal').map(&:slug).first).to eq('delete-a-deal')
  end
end
