# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Guide::TourDrafter do
  before do
    Knowledge::Snapshot.create!(
      source: 'frontend', snapshot_at: Time.current, modules_hash: 'x',
      atlas: {
        'entries' => [
          { 'key' => 'page:/deals', 'kind' => 'page', 'title' => 'Sales Deals', 'route' => '/deals', 'breadcrumb' => ['CRM & Sales'],
            'where' => [{ 'anchor' => 'nav-section:crm-sales', 'title' => 'CRM & Sales', 'text' => 'Open CRM & Sales.', 'click' => true },
                        { 'anchor' => 'nav:/deals', 'title' => 'Sales Deals', 'text' => 'Click Sales Deals.', 'click' => true }] },
          { 'key' => 'page:/lot-map', 'kind' => 'page', 'title' => 'Lot Map', 'route' => '/lot-map', 'requires' => [{ 'adminOnly' => true }],
            'where' => [{ 'anchor' => 'nav:/lot-map', 'title' => 'Lot Map', 'text' => 'Click Lot Map.', 'click' => true }] }
        ],
        'markers' => { 'add-button' => ['/deals'], 'main-table' => ['/crm'] }
      }
    )
  end

  let(:client) do
    Class.new do
      def self.call(**)
        { input: { 'name' => 'Start a deal', 'description' => 'From the menu to a new deal — fast.', 'steps' => [
          { 'place_key' => 'page:/deals', 'title' => 'Your deals', 'text' => 'Every deal lives here.' },
          { 'marker' => 'add-button', 'route' => '/deals', 'title' => 'New deal', 'text' => 'Start one here.' },
          { 'marker' => 'made-up', 'route' => '/deals', 'title' => 'Nope', 'text' => 'Invented' },
          { 'marker' => 'main-table', 'route' => '/deals', 'title' => 'Nope', 'text' => 'Real marker, wrong page' },
          { 'marker' => 'main-table', 'route' => '/crm', 'title' => 'Nope', 'text' => 'Real marker on its page, but the tour is not there' },
          { 'marker' => 'add-button', 'route' => '/not-a-page', 'title' => 'Nope', 'text' => 'Wrong page' },
          { 'place_key' => 'page:/nowhere', 'title' => 'Nope', 'text' => 'Invented place' },
          { 'place_key' => 'page:/lot-map', 'title' => 'Nope', 'text' => 'Admin only' }
        ] } }
      end
    end
  end

  it 'builds steps only from the Atlas menu walk and real markers on real pages' do
    draft = described_class.new('teach a rep to start a deal', client: client).draft

    expect(draft[:steps].map { |s| s[:selector] }).to eq([
      '[data-tour="nav-section:crm-sales"]', '[data-tour="nav:/deals"]', '[data-tour="add-button"]'
    ])
    expect(draft[:steps][1]).to include(title: 'Your deals', content: 'Every deal lives here.', click_required: true)
    expect(draft[:steps].map { |s| s[:position] }).to eq([1, 2, 3])
    expect(draft[:description]).to eq('From the menu to a new deal, fast.')
  end

  it 'does not open a menu section a second time' do
    twice = Class.new do
      def self.call(**)
        { input: { 'name' => 'Deals twice', 'description' => 'x', 'steps' => [
          { 'place_key' => 'page:/deals', 'title' => 'One', 'text' => 'a' },
          { 'place_key' => 'page:/deals', 'title' => 'Two', 'text' => 'b' }
        ] } }
      end
    end
    selectors = described_class.new('deals', client: twice).draft[:steps].map { |s| s[:selector] }
    expect(selectors.count('[data-tour="nav-section:crm-sales"]')).to eq(1)
  end

  it 'refuses without a goal' do
    expect { described_class.new('  ', client: client).draft }.to raise_error(ArgumentError)
  end
end
