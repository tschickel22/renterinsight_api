# frozen_string_literal: true

require 'rails_helper'

# A photo post used to store the photo object id instead of the story id, so
# its comments were read off the wrong node and the Page strip could never
# match the card back to our row.
RSpec.describe MetaGraphApi, '.published_post_id' do
  it 'prefers the story id a photo post returns alongside the photo id' do
    result = { 'id' => '122121800217387211', 'post_id' => '1280160285171602_122121815625387211' }

    expect(described_class.published_post_id(result)).to eq('1280160285171602_122121815625387211')
  end

  it 'falls back to id for a feed post, which returns only that' do
    result = { 'id' => '1280160285171602_122121815625387211' }

    expect(described_class.published_post_id(result)).to eq('1280160285171602_122121815625387211')
  end

  it 'ignores a blank post_id rather than storing nothing' do
    result = { 'id' => '985224884083103', 'post_id' => '' }

    expect(described_class.published_post_id(result)).to eq('985224884083103')
  end

  it 'returns nil when Meta sends back something unexpected' do
    expect(described_class.published_post_id(nil)).to be_nil
    expect(described_class.published_post_id('ok')).to be_nil
    expect(described_class.published_post_id({})).to be_nil
  end
end
