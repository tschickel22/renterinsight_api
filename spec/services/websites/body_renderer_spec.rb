# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::BodyRenderer do
  let(:company) { Company.create!(name: 'Mobile Home Masters') }
  let(:location) { company.locations.create!(name: 'Lot') }
  let(:website) do
    # brand.company_name is what a scanned site carries and what PageMetadata
    # titles pages with, so the body has to agree with the head.
    Website.create!(company_id: company.id, location_id: location.id, name: 'MHM',
                    slug: "s-#{SecureRandom.hex(4)}",
                    brand: { 'company_name' => 'Mobile Home Masters' })
  end

  # Shapes copied from a real published site rather than invented, so the
  # renderer is exercised against the keys templates actually produce.
  let(:blocks) do
    [
      { 'type' => 'hero', 'order' => 1, 'content' => {
        'title' => 'WELCOME TO MOBILE HOME MASTERS',
        'subtitle' => 'The go-to dealer for manufactured homes in East Texas since 1999.',
        'backgroundImage' => 'https://cdn.test/hero.jpg'
      } },
      { 'type' => 'features', 'order' => 3, 'content' => {
        'title' => 'Why Families Choose Us',
        'features' => [
          { 'icon' => 'x', 'title' => 'Quality Built Homes', 'description' => 'Built by top manufacturers.' },
          { 'icon' => 'y', 'title' => 'Custom Floor Plans', 'description' => 'From single wide to multi-section.' }
        ]
      } },
      { 'type' => 'inventory', 'order' => 2, 'content' => { 'title' => 'Available Homes' } }
    ]
  end

  let(:page) { website.website_pages.create!(title: 'Home', path: '/', order: 0, blocks: blocks) }

  def render(page: nil, vehicle: nil)
    described_class.new(website: website, page: page, canonical_host: 'mhm.test',
                        vehicle: vehicle).call
  end

  describe 'a content page' do
    subject(:html) { render(page: page) }

    it 'emits the words a visitor sees' do
      expect(html).to include('WELCOME TO MOBILE HOME MASTERS')
      expect(html).to include('The go-to dealer for manufactured homes in East Texas since 1999.')
      expect(html).to include('Quality Built Homes')
      expect(html).to include('Built by top manufacturers.')
    end

    # Exactly one h1, which is both correct structure and what our own SeoAudit
    # checks. Before this the served body had no headings at all.
    it 'has one h1 and steps later headings down' do
      expect(html.scan('<h1>').size).to eq(1)
      expect(html).to include('<h2>Why Families Choose Us</h2>')
    end

    it 'gives images alt text rather than leaving it empty' do
      expect(html).to include('alt="WELCOME TO MOBILE HOME MASTERS"')
    end

    # A crawler must be able to walk the site without executing the nav.
    it 'links to the site\'s other pages' do
      website.website_pages.create!(title: 'Contact', path: '/contact', order: 5)

      expect(render(page: page)).to include('<a href="/contact">Contact</a>')
    end

    # The grid is JavaScript by nature. Its crawlable form is the per-home pages
    # in the sitemap, not an imitation grid here.
    it 'skips interactive blocks instead of faking them' do
      expect(html).not_to include('Available Homes')
    end

    it 'sits in its own container so the mount-failure check still works' do
      expect(html).to include('id="dt-prerender"')
    end
  end

  describe 'an imported design' do
    # A customHtml block stores its stylesheet under the same "html" key its
    # copy lives under. Rails' sanitize drops a disallowed TAG and keeps what
    # was inside it, so the CSS reached the crawlable body as prose and a
    # visitor watched a page of it render before React replaced it.
    let(:design) do
      [{ 'type' => 'customHtml', 'order' => 1, 'content' => {
        'html' => '<style>:host{--navy-950:#071528}.hero{background:red}</style>' \
                  '<h1>Your buyers are calling</h1>' \
                  '<p>One connected system, first click to final warranty.</p>' \
                  '<script>steal()</script>'
      } }]
    end

    let(:page) do
      website.website_pages.create!(title: 'DT V4', path: '/dt-v4', blocks: design)
    end

    subject(:html) do
      described_class.new(website: website, page: page, canonical_host: 'x.test').call
    end

    it 'keeps the words a visitor reads' do
      expect(html).to include('Your buyers are calling')
      expect(html).to include('One connected system')
    end

    it 'does not put the stylesheet in front of a crawler as prose' do
      expect(html).not_to include('--navy-950')
      expect(html).not_to include(':host')
      expect(html).not_to include('background:red')
    end

    it 'drops script text as well' do
      expect(html).not_to include('steal()')
    end
  end

  describe 'a page with nothing renderable' do
    # Otherwise the site we just built would be flagged by our own audit for
    # having no H1.
    it 'still emits a heading from the page title' do
      bare = website.website_pages.create!(title: 'Inventory', path: '/inventory', order: 1,
                                           blocks: [{ 'type' => 'inventory', 'content' => {} }])

      expect(render(page: bare)).to include('<h1>Inventory</h1>')
    end

    it 'returns nothing at all when there are no blocks' do
      empty = website.website_pages.create!(title: 'Empty', path: '/empty', order: 2, blocks: [])

      expect(render(page: empty)).to be_nil
    end
  end

  describe 'a home' do
    let(:vehicle) do
      company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes',
                               model: 'Prairie Dune', status: 'available', bedrooms: 3,
                               bathrooms: 2, square_feet: 1023, sale_price: 89_900,
                               images: [{ 'url' => 'https://cdn.test/front.jpg' }])
    end

    subject(:html) { render(page: page, vehicle: vehicle) }

    it 'reads as the product page it is' do
      expect(html).to include('<h1>2026 Skyline Homes Prairie Dune</h1>')
      expect(html).to include('3 bedrooms')
      expect(html).to include('1,023 square feet')
      expect(html).to include('Price: $89,900')
    end

    it 'shows the home\'s own photograph' do
      expect(html).to include('src="https://cdn.test/front.jpg"')
    end

    it 'says where the home can be bought' do
      expect(html).to include('This home is available from Mobile Home Masters')
    end

    # A listing with no dealer-written description rendered 33 words, which is
    # under any threshold for a page having a subject, and 140 of this site's
    # URLs are listings.
    it 'carries enough copy to rank even when the dealer wrote no description' do
      bare = company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes',
                                      model: 'Prairie Dune 8710', status: 'available',
                                      bedrooms: 3, bathrooms: 2, square_feet: 1023,
                                      sections: 1, home_type: 'hud', condition: 'new')
      6.times do |i|
        company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes',
                                 model: "Shore Park #{i}", status: 'available',
                                 bedrooms: 3, bathrooms: 2, square_feet: 1100)
      end

      words = ActionController::Base.helpers.strip_tags(render(page: page, vehicle: bare)).split.size
      expect(words).to be >= 150
    end

    # Read off the record, never composed. A dealer's product claims are theirs
    # to make.
    it 'states the specs in prose without asserting anything the dealer did not enter' do
      hud = company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes',
                                     model: 'Prairie Dune', status: 'available', bedrooms: 3,
                                     bathrooms: 2, square_feet: 1023, sections: 1,
                                     home_type: 'hud', condition: 'new')

      expect(render(page: page, vehicle: hud)).to include(
        'The 2026 Skyline Homes Prairie Dune is a new single section HUD home with 3 bedrooms, ' \
        '2 bathrooms and 1,023 square feet of living space.'
      )
    end

    it 'links to the rest of the lot, so a crawler can reach listings without the sitemap' do
      other = company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes',
                                       model: 'Shore Park', status: 'available', bedrooms: 2)

      expect(html).to include(Websites::HomeUrl.path_for(other))
      expect(html).to include('More homes at Mobile Home Masters')
    end

    it 'never links to a home the site would refuse to serve' do
      sold = company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes',
                                      model: 'Sold Already', status: 'sold', bedrooms: 2)

      expect(html).not_to include(Websites::HomeUrl.path_for(sold))
    end
  end

  # Was skipped entirely, which left the inventory page at 52 words with nothing
  # linking to a home except the sitemap.
  describe 'an inventory block' do
    let(:listing_page) do
      website.website_pages.create!(
        title: 'Inventory', path: '/inventory', order: 9,
        blocks: [{ 'type' => 'inventory', 'order' => 0, 'content' => { 'title' => 'Our Homes' } }]
      )
    end

    it 'renders the homes actually on the lot, linked' do
      home = company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Skyline Homes',
                                      model: 'Prairie Dune', status: 'available',
                                      bedrooms: 3, bathrooms: 2, square_feet: 1023)

      html = render(page: listing_page)

      expect(html).to include('Our Homes')
      expect(html).to include(Websites::HomeUrl.path_for(home))
      expect(html).to include('2026 Skyline Homes Prairie Dune')
      expect(html).to include('3 bed, 2 bath, 1,023 sq ft')
    end

    it 'still gives the page a heading when the lot is empty' do
      expect(render(page: listing_page)).to include('<h1>')
    end
  end

  # The contact page rendered 55 words on a live site while carrying hours, a
  # phone number and an address, because the text block stores its whole body
  # under "html" and the map block was skipped wholesale.
  describe 'contact details' do
    let(:contact_page) do
      website.website_pages.create!(
        title: 'Contact', path: '/contact', order: 11,
        blocks: [
          { 'type' => 'map', 'order' => 0, 'content' => {
            'title' => 'Visit Our Showroom',
            'address' => '123 Dealer Drive, Your City, ST 12345',
            'embedUrl' => 'https://maps.example/embed'
          } },
          { 'type' => 'text', 'order' => 1, 'content' => {
            'html' => '<h2>Hours</h2><div style="display: grid"><p><strong>Phone:</strong> ' \
                      '(555) 123-4567</p></div>'
          } }
        ]
      )
    end

    subject(:html) { render(page: contact_page) }

    it 'keeps the street address that the map block was throwing away' do
      expect(html).to include('123 Dealer Drive, Your City, ST 12345')
    end

    it 'renders authored rich text instead of dropping it' do
      expect(html).to include('Hours')
      expect(html).to include('(555) 123-4567')
    end

    it 'keeps the structure and drops the builder\'s inline styling' do
      expect(html).to include('<h2>Hours</h2>')
      expect(html).to include('<strong>Phone:</strong>')
      expect(html).not_to include('display: grid')
    end

    it 'never emits a second h1 from authored copy' do
      page = website.website_pages.create!(
        title: 'Rich', path: '/rich', order: 12,
        blocks: [{ 'type' => 'text', 'order' => 0, 'content' => { 'html' => '<h1>Second</h1>' } }]
      )

      expect(render(page: page).scan('<h1').size).to eq(1)
    end

    it 'cannot be scripted through authored html' do
      page = website.website_pages.create!(
        title: 'Nasty', path: '/nasty', order: 13,
        blocks: [{ 'type' => 'text', 'order' => 0,
                   'content' => { 'html' => '<p>ok</p><script>alert(1)</script>' } }]
      )

      expect(render(page: page)).not_to include('<script>')
    end
  end

  # Local search ranks on a consistent name, address and phone, and ours appeared
  # only inside JSON-LD. Structured data is also meant to describe what a visitor
  # can see, so a store node asserting an address that appears nowhere on the
  # page is the weaker kind of markup.
  describe 'the dealership footer' do
    it 'names the lot the site belongs to when it has a street' do
      location.update!(address_line1: '123 Dealer Drive', city: 'Denver', state: 'CO', phone: '(555) 123-4567')

      html = render(page: page)

      expect(html).to include('123 Dealer Drive')
      expect(html).to include('Denver, CO')
      expect(html).to include('Phone: (555) 123-4567')
    end

    # Locations are routinely created with a name and nothing else, which used to
    # silence the equivalent JSON-LD node for a company whose address was sitting
    # right there.
    it 'falls back to the company when the location has no street' do
      company.update!(address_line1: '9 Head Office Way', city: 'Dallas', state: 'TX')

      expect(render(page: page)).to include('9 Head Office Way')
    end

    it 'stays silent rather than printing an empty address' do
      expect(render(page: page)).not_to include('<address>')
    end
  end

  describe 'escaping' do
    it 'cannot be broken out of by a dealer\'s own copy' do
      nasty = website.website_pages.create!(
        title: 'X', path: '/x', order: 3,
        blocks: [{ 'type' => 'text', 'content' => { 'title' => '<script>alert(1)</script>' } }]
      )

      html = render(page: nasty)

      expect(html).not_to include('<script>')
      expect(html).to include('&lt;script&gt;')
    end
  end
end
