# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::BookingPrefill do
  def params(url)
    URI.decode_www_form(URI.parse(url).query.to_s).to_h
  end

  describe 'providers that take one name field' do
    it 'fills Calendly' do
      url = described_class.apply('https://calendly.com/summit-park/showing',
                                  name: 'Jane Doe', email: 'jane@example.com')

      expect(params(url)).to eq('name' => 'Jane Doe', 'email' => 'jane@example.com')
    end

    # An unanchored /cal\.com/ also matches savvycal.com, which would have sent
    # SavvyCal the wrong parameter name and prefilled nothing at all.
    it 'fills cal.com and SavvyCal under their own parameter names' do
      cal = described_class.apply('https://cal.com/summit/tour', name: 'Jane Doe')
      savvy = described_class.apply('https://savvycal.com/summit/tour', name: 'Jane Doe')

      expect(params(cal)['name']).to eq('Jane Doe')
      expect(params(savvy)['display_name']).to eq('Jane Doe')
    end
  end

  describe 'providers that insist on two name fields' do
    it 'splits the name for HubSpot' do
      url = described_class.apply('https://meetings.hubspot.com/summit',
                                  name: 'Jane Van Doe', email: 'jane@example.com')

      expect(params(url)).to eq('firstName' => 'Jane', 'lastName' => 'Van Doe',
                                'email' => 'jane@example.com')
    end

    # Splitting a single word into a surname would put a name in front of the
    # dealer that the visitor never gave.
    it 'leaves a one-word name as a first name only' do
      url = described_class.apply('https://meetings.hubspot.com/summit', name: 'Jane')

      expect(params(url)).to eq('firstName' => 'Jane')
    end

    it 'passes a phone number to Acuity, which accepts one' do
      url = described_class.apply('https://summitpark.acuityscheduling.com/schedule.php',
                                  name: 'Jane Doe', phone: '555-1234')

      expect(params(url)['phone']).to eq('555-1234')
    end
  end

  describe 'when we should not touch it' do
    # A guessed parameter shows up as a stray field or an error on somebody
    # else's booking page, which is a dealer's first impression of a buyer.
    it 'leaves an unrecognised scheduler exactly as it is' do
      url = 'https://booking.some-dealer-crm.com/summit?ref=site'

      expect(described_class.apply(url, name: 'Jane Doe', email: 'jane@example.com')).to eq(url)
    end

    it 'leaves the link alone when the visitor has told us nothing' do
      url = 'https://calendly.com/summit-park/showing'

      expect(described_class.apply(url)).to eq(url)
    end

    it 'returns nil and blank untouched, since no scheduler is configured' do
      expect(described_class.apply(nil, name: 'Jane')).to be_nil
      expect(described_class.apply('', name: 'Jane')).to eq('')
    end

    it 'does not raise on whatever a dealer pasted into the field' do
      expect(described_class.apply('not a url at all', name: 'Jane')).to eq('not a url at all')
      expect(described_class.apply('mailto:sales@dealer.com', name: 'Jane')).to eq('mailto:sales@dealer.com')
    end
  end

  describe 'parameters the dealer already set' do
    it 'keeps their own query string' do
      url = described_class.apply('https://calendly.com/summit-park/showing?utm_source=site',
                                  name: 'Jane Doe')

      expect(params(url)).to include('utm_source' => 'site', 'name' => 'Jane Doe')
    end

    # They know something about their own booking flow that we do not.
    it 'never overwrites a value they pinned themselves' do
      url = described_class.apply('https://calendly.com/summit-park/showing?name=Walk%20In',
                                  name: 'Jane Doe')

      expect(params(url)['name']).to eq('Walk In')
    end
  end
end
