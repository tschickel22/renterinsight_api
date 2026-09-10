# frozen_string_literal: true

require 'rails_helper'

# Headless Chrome, in this container. Verified against the live site it was
# written for: thehomeplus.com goes from one unreadable page to seven real ones
# (home, move-in-ready homes, about-us, financing, contact, map, start), with
# the logo and brand colours recovered.
#
# These examples cover the parts that decide whether that happens: when to stop
# waiting, and never leaving a browser running.
RSpec.describe SiteProfiles::LocalBrowser do
  let(:browser) { described_class.new }

  # The real wait is twenty seconds. Every example here is about what the loop
  # decides, not how long it is prepared to wait for it.
  before { stub_const("#{described_class}::SETTLE_TIMEOUT", 1) }
  let(:driver) { instance_double(Selenium::WebDriver::Chrome::Driver) }

  def stub_driver(page_source:, stats: { 'ready' => true, 'words' => 400, 'links' => 20 })
    navigation = instance_double(Selenium::WebDriver::Navigation, to: nil)
    allow(driver).to receive(:navigate).and_return(navigation)
    allow(driver).to receive(:page_source).and_return(page_source)
    allow(driver).to receive(:quit)
    allow(driver).to receive(:execute_script) do |script|
      script.include?('scrollTo') ? nil : stats
    end
    # The ivar rather than a stubbed reader, so memoisation and #close run for
    # real — close reads @driver, and stubbing the method left it nil.
    browser.instance_variable_set(:@driver, driver)
  end

  it 'returns the document once the page has drawn itself' do
    stub_driver(page_source: '<html><body><h1>Sunshine Homes</h1></body></html>')

    expect(browser.render('https://dealer.com/')).to include('Sunshine Homes')
  end

  # The bug this class exists to avoid, in miniature: a Next.js page serves
  # 700KB of streaming payload before any of it becomes markup. Reading at that
  # instant gave a five word profile of a site with 368.
  it 'keeps waiting while the framework has drawn nothing yet' do
    stub_driver(page_source: '<html><body><script>__next_f.push()</script></body></html>',
                stats: { 'ready' => true, 'words' => 3, 'links' => 0 })
    allow(browser).to receive(:sleep)

    browser.render('https://dealer.com/')

    # Polled rather than returned on the first look.
    expect(browser).to have_received(:sleep).at_least(5).times
  end

  it 'gives the page back anyway once the wait is spent' do
    stub_driver(page_source: '<html><body>thin but real</body></html>',
                stats: { 'ready' => true, 'words' => 5, 'links' => 0 })
    allow(browser).to receive(:sleep)

    expect(browser.render('https://dealer.com/')).to include('thin but real')
  end

  it 'closes the browser when it is done with it' do
    stub_driver(page_source: '<html><body><h1>Homes</h1></body></html>')
    browser.render('https://dealer.com/')

    browser.close

    expect(driver).to have_received(:quit)
  end

  # A scan must survive a browser that dies, and must not spend the rest of its
  # ten pages relaunching one that cannot start.
  it 'reports nothing and stands down when Chrome will not run' do
    allow(Selenium::WebDriver).to receive(:for).and_raise(Selenium::WebDriver::Error::WebDriverError)

    expect(browser.render('https://dealer.com/')).to be_nil
    expect(browser).not_to be_available
  end

  it 'stops trying after the first failure' do
    allow(Selenium::WebDriver).to receive(:for).and_raise(Selenium::WebDriver::Error::WebDriverError)
    browser.render('https://dealer.com/')

    browser.render('https://dealer.com/other')

    expect(Selenium::WebDriver).to have_received(:for).once
  end
end
