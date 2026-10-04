# frozen_string_literal: true

require 'rails_helper'

# Currency fields used to stamp exactly what was stored, so a formula total
# printed as "79064.0" and a typed price as "87489" beside the form's "$".
RSpec.describe AgreementPdfService, 'currency stamping' do
  let(:service) { described_class.allocate }

  it 'formats amounts with separators and cents' do
    expect(service.send(:format_currency, '87489')).to eq('87,489.00')
    expect(service.send(:format_currency, '79064.0')).to eq('79,064.00')
    expect(service.send(:format_currency, '4971.51')).to eq('4,971.51')
  end

  it 'reads amounts that were typed with a dollar sign or commas' do
    expect(service.send(:format_currency, '$1,240')).to eq('1,240.00')
  end

  it 'keeps negatives' do
    expect(service.send(:format_currency, '-8425')).to eq('-8,425.00')
  end

  it 'stamps anything that is not an amount as given' do
    expect(service.send(:format_currency, 'Per lender')).to eq('Per lender')
  end
end
