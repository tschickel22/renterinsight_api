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
          { 'key' => 'page:/settings', 'kind' => 'page', 'title' => 'Company Settings', 'route' => '/settings', 'requires' => [],
            'where' => [{ 'anchor' => 'nav-section:administration', 'title' => 'Administration', 'text' => 'Open it.', 'click' => true },
                        { 'anchor' => 'nav:/settings', 'title' => 'Company Settings', 'text' => 'Click it.', 'click' => true }] },
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

  it 'opens a section again after another one has closed it' do
    back_and_forth = Class.new do
      def self.call(**)
        { input: { 'name' => 'x', 'description' => 'x', 'steps' => [
          { 'place_key' => 'page:/deals', 'title' => 'One', 'text' => 'a' },
          { 'place_key' => 'page:/settings', 'title' => 'Two', 'text' => 'b' },
          { 'place_key' => 'page:/deals', 'title' => 'Three', 'text' => 'c' }
        ] } }
      end
    end
    selectors = described_class.new('x', client: back_and_forth).draft[:steps].map { |s| s[:selector] }
    expect(selectors.count('[data-tour="nav-section:crm-sales"]')).to eq(2)
  end

  it 'follows an action into its form and allows that form\'s markers' do
    Knowledge::Snapshot.create!(
      source: 'frontend', snapshot_at: 1.minute.from_now, modules_hash: 'z',
      atlas: {
        'entries' => [
          { 'key' => 'action:new-deal', 'kind' => 'action', 'title' => 'Start a deal', 'route' => '/deals/new', 'requires' => [],
            'where' => [{ 'anchor' => 'nav:/deals', 'title' => 'Deals', 'text' => 'Click Deals.', 'click' => true },
                        { 'route' => '/deals', 'anchor' => 'add-button', 'title' => 'Start a deal', 'text' => 'Click New.', 'click' => true }] }
        ],
        'markers' => { 'deal-form:name' => ['/deals/new'], 'deal-form:save' => ['/deals/new'], '#dealNotes' => ['/deals/new'] },
        'marker_labels' => { '#dealNotes' => 'Notes' }
      }
    )
    form = Class.new do
      def self.call(**)
        { input: { 'name' => 'Start a deal', 'description' => 'x', 'steps' => [
          { 'place_key' => 'action:new-deal', 'title' => 'New deal', 'text' => 'Click New.' },
          { 'marker' => 'deal-form:name', 'route' => '/deals/new', 'title' => 'Name it', 'text' => 'Give it a name.' },
          { 'marker' => 'deal-form:name', 'route' => '/deals/new', 'title' => 'Again', 'text' => 'Repeat.' },
          { 'marker' => '#dealNotes', 'route' => '/deals/new', 'title' => 'Notes', 'text' => 'Add notes.' },
          { 'marker' => 'deal-form:save', 'route' => '/deals/new', 'title' => 'Save', 'text' => 'Save it.' }
        ] } }
      end
    end
    selectors = described_class.new('start a deal', client: form).draft[:steps].map { |s| s[:selector] }
    expect(selectors).to eq(['[data-tour="nav:/deals"]', '[data-tour="add-button"]', '[data-tour="deal-form:name"]',
                             '[id="dealNotes"]', '[data-tour="deal-form:save"]'])
  end

  it 'stops at the save, keeps steps that must be pressed, and trims long tours from the fields' do
    Knowledge::Snapshot.create!(
      source: 'frontend', snapshot_at: 2.minutes.from_now, modules_hash: 'w',
      atlas: {
        'entries' => [
          { 'key' => 'action:new-x', 'kind' => 'action', 'title' => 'New x', 'route' => '/x/new', 'requires' => [],
            'where' => [{ 'route' => '/x', 'anchor' => 'x-new', 'title' => 'New', 'text' => 'Click New.', 'click' => true }] },
          { 'key' => 'page:/reports', 'kind' => 'page', 'title' => 'Reports', 'route' => '/reports', 'requires' => [],
            'where' => [{ 'anchor' => 'nav:/reports', 'title' => 'Reports', 'text' => 'Click Reports.', 'click' => true }] }
        ],
        'markers' => { 'x-type-a' => ['/x/new'], 'x-form:save' => ['/x/new'] }.merge((1..14).to_h { |n| ["#f#{n}", ['/x/new']] })
      }
    )
    long = Class.new do
      def self.call(**)
        fields = (1..14).map { |n| { 'marker' => "#f#{n}", 'route' => '/x/new', 'title' => "F#{n}", 'text' => '.' } }
        { input: { 'name' => 'x', 'description' => 'x', 'steps' => [
          { 'place_key' => 'action:new-x', 'title' => 'New', 'text' => '.' },
          { 'marker' => 'x-type-a', 'route' => '/x/new', 'title' => 'Pick A', 'text' => '.', 'click' => true },
          *fields,
          { 'marker' => 'x-form:save', 'route' => '/x/new', 'title' => 'Save', 'text' => '.' },
          { 'place_key' => 'page:/reports', 'title' => 'Detour', 'text' => '.' }
        ] } }
      end
    end
    steps = described_class.new('make an x', client: long).draft[:steps]

    expect(steps.size).to eq(12)
    expect(steps.last[:selector]).to eq('[data-tour="x-form:save"]')
    expect(steps.find { |s| s[:selector] == '[data-tour="x-type-a"]' }[:click_required]).to eq(true)
    expect(steps.map { |s| s[:selector] }).not_to include('[data-tour="nav:/reports"]')
  end

  it 'starts from the action that matches the goal and does not leave it' do
    Knowledge::Snapshot.create!(
      source: 'frontend', snapshot_at: 3.minutes.from_now, modules_hash: 'v',
      atlas: {
        'entries' => [
          { 'key' => 'action:new-contact', 'kind' => 'action', 'title' => 'Add a contact', 'route' => '/contacts/new', 'requires' => [],
            'synonyms' => ['new contact', 'add customer'],
            'where' => [{ 'route' => '/contacts', 'anchor' => 'contacts-add', 'title' => 'Add', 'text' => 'Click Add.', 'click' => true }] },
          { 'key' => 'page:/accounts', 'kind' => 'page', 'title' => 'Accounts', 'route' => '/accounts', 'requires' => [],
            'where' => [{ 'anchor' => 'nav:/accounts', 'title' => 'Accounts', 'text' => 'Click Accounts.', 'click' => true }] }
        ],
        'markers' => { 'contact-form:save' => ['/contacts/new'] }
      }
    )
    wanders = Class.new do
      def self.call(**)
        { input: { 'name' => 'x', 'description' => 'x', 'steps' => [
          { 'place_key' => 'page:/accounts', 'title' => 'Accounts', 'text' => '.' },
          { 'marker' => 'contact-form:save', 'route' => '/contacts/new', 'title' => 'Save', 'text' => '.' }
        ] } }
      end
    end
    selectors = described_class.new('Add a contact to your list', client: wanders).draft[:steps].map { |s| s[:selector] }
    expect(selectors).to eq(['[data-tour="contacts-add"]', '[data-tour="contact-form:save"]'])
  end

  it 'refuses without a goal' do
    expect { described_class.new('  ', client: client).draft }.to raise_error(ArgumentError)
  end
end
