# frozen_string_literal: true

require 'rails_helper'

# The how it works notes (E118) load, stay free of dashes, and are what help
# search finds for "how does this post" questions.
RSpec.describe 'How it works notes' do
  FILES = %w[how_it_works_accounting how_it_works_commissions].freeze

  before do
    %w[accounting commissions].each do |key|
      Knowledge::Module.find_by(key: key) || Knowledge::Module.create!(key: key, name: key.titleize)
    end
    FILES.each { |f| Guide::ArticleLoader.load!(Rails.root.join("db/guide/#{f}.yml")) }
  end

  it 'loads every note, published, with no em or en dashes' do
    notes = Knowledge::Article.where('slug LIKE ?', 'how-it-works-%')
    expect(notes.count).to eq(18)
    expect(notes.where(is_published: false)).to be_empty
    notes.each do |n|
      expect("#{n.title} #{n.excerpt} #{n.content}").not_to match(/[–—]/), n.slug
      expect(n.content).not_to include('DealerTide')
    end
  end

  it 'is what help search finds for posting and commission questions' do
    expect(Guide::HelpSearch.call('how does a deal post to the books when approved').map(&:slug))
      .to include('how-it-works-deal-posting')
    expect(Guide::HelpSearch.call('is freight included in commission house profit').map(&:slug))
      .to include('how-it-works-commission-basis')
    expect(Guide::HelpSearch.call('how does reconciliation work').map(&:slug))
      .to include('how-it-works-bank-reconciliation')
  end

  it 'links only to notes that exist' do
    slugs = Knowledge::Article.pluck(:slug)
    Knowledge::Article.where('slug LIKE ?', 'how-it-works-%').find_each do |n|
      n.content.scan(/\]\((how-it-works-[a-z0-9-]+)\)/).flatten.each do |link|
        expect(slugs).to include(link), "#{n.slug} links to #{link}"
      end
    end
  end
end
