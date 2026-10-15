# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UsPhone do
  it 'writes a US number one way, however it was typed' do
    ['3035864420', '(303) 586-4420', '303.586.4420', '+1 303 586 4420', '1-303-586-4420', ' 303-586-4420 '].each do |typed|
      expect(described_class.format(typed)).to eq('303-586-4420'), typed
    end
  end

  it 'keeps what is not a 10 digit US number as typed' do
    expect(described_class.format('+44 20 7946 0958')).to eq('+44 20 7946 0958')
    expect(described_class.format('303-586-4420 x12')).to eq('303-586-4420 x12')
    expect(described_class.format('555-1234')).to eq('555-1234')
    expect(described_class.format('')).to eq('')
    expect(described_class.format(nil)).to be_nil
  end

  describe 'on records' do
    let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }

    it 'stores leads, contacts and accounts the same way, and finds them by any form' do
      lead = company.leads.create!(first_name: 'Pat', last_name: 'Smith', phone: '(303) 586-4420', co_applicant_phone: '7205551234')
      expect(lead.reload).to have_attributes(phone: '303-586-4420', co_applicant_phone: '720-555-1234')
      expect(company.leads.where(phone: '3035864420')).to include(lead)

      contact = company.contacts.create!(first_name: 'Pat', last_name: 'Smith', phone: '+1 303.586.4420')
      expect(contact.reload.phone).to eq('303-586-4420')

      account = company.accounts.create!(name: 'Smith Household', phone: '303 586 4420')
      expect(account.reload.phone).to eq('303-586-4420')
    end

    it 'backfills existing rows without touching updated_at' do
      lead = company.leads.create!(first_name: 'Pat', last_name: 'Smith')
      lead.update_columns(phone: '(303) 586-4420', updated_at: 2.days.ago)
      stamp = lead.reload.updated_at
      ActiveRecord::Base.connection.exec_update(described_class.backfill_sql(:leads, :phone))
      expect(lead.reload).to have_attributes(phone: '303-586-4420', updated_at: stamp)
    end
  end
end
