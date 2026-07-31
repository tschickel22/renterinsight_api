# frozen_string_literal: true

require 'rails_helper'

# "CC me" copies the submitting user on the claim email the manufacturer gets,
# so the dealer holds a sent copy of exactly what the factory received. A CC is
# a convenience: a malformed or duplicate address must never cost the
# manufacturer their copy, so the list is scrubbed rather than rejected.
RSpec.describe WarrantyNotificationService, '.normalize_cc_addresses' do
  subject(:normalize) { described_class.method(:normalize_cc_addresses) }

  it 'keeps a single valid address' do
    expect(normalize.call(['tom@dealer.com'])).to eq('tom@dealer.com')
  end

  it 'accepts a comma or semicolon separated string as several addresses' do
    expect(normalize.call('tom@dealer.com, service@dealer.com'))
      .to eq('tom@dealer.com, service@dealer.com')
    expect(normalize.call(['tom@dealer.com;service@dealer.com']))
      .to eq('tom@dealer.com, service@dealer.com')
  end

  it 'returns nil when nothing usable is left, so the send is unchanged' do
    expect(normalize.call([])).to be_nil
    expect(normalize.call(nil)).to be_nil
    expect(normalize.call(['', '   ', 'not-an-email'])).to be_nil
  end

  it 'drops the primary recipient rather than sending them two copies' do
    expect(normalize.call(['claims@factory.com'], exclude: 'Claims@Factory.com')).to be_nil
  end

  it 'de-duplicates case-insensitively' do
    expect(normalize.call(['tom@dealer.com', 'TOM@dealer.com'])).to eq('tom@dealer.com')
  end

  it 'keeps the good addresses when one entry is junk' do
    expect(normalize.call(['tom@dealer.com', 'oops'])).to eq('tom@dealer.com')
  end
end
