# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TrainingVideo, '.search' do
  def video(title, lines, chapters)
    described_class.new(title: title, chapters: chapters, transcript: lines.join("\n"))
  end

  let(:locations) do
    video('Locations settings',
          ['0:04 Open the location list.', '0:25 Press Add Location to create a new one.',
           '0:42 The menu can deactivate or delete it.'],
          [{ 'title' => 'Find it', 'start' => 4 }, { 'title' => 'Add a location', 'start' => 25, 'terms' => 'store, lot, branch' },
           { 'title' => 'Inside a location', 'start' => 42, 'terms' => 'close, shut down' }])
  end
  let(:general) do
    video('General settings', ['0:14 Your company name and address live here.'], [{ 'title' => 'Company information', 'start' => 14 }])
  end
  let(:videos) { [general, locations] }

  def top(query)
    described_class.search(query, scope: videos).first
  end

  it 'matches whole words, so a short word does not hit a longer one' do
    expect(described_class.search('add', scope: [general])).to be_empty
    expect(top('address').first).to eq(general)
  end

  it 'finds a word with a different ending' do
    expect(top('locations').first).to eq(locations)
    expect(top('deactivating').first).to eq(locations)
    expect(top('changing company names').first).to eq(general)
  end

  it 'finds hidden chapter terms the narrator never says, at that chapter' do
    video, moment = top('another store')
    expect(video).to eq(locations)
    expect(moment).to eq(start: 25, label: 'Add a location')

    video, moment = top('close a location')
    expect(video).to eq(locations)
    expect(moment).to eq(start: 42, label: 'Inside a location')
  end

  it 'finds nothing when no word matches' do
    expect(described_class.search('zebra', scope: videos)).to be_empty
  end

  it 'still works with no chapters or transcript' do
    bare = described_class.new(title: 'Bids')
    expect(described_class.search('bids', scope: [bare]).first.last).to eq(start: 0, label: nil)
  end
end
