# frozen_string_literal: true

require 'rails_helper'

# Imported household accounts get their person (Tom, 2026-11-22).
RSpec.describe Accounts::HouseholdContact do
  let(:company) { Company.create!(name: "HH #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }

  def account(name, **attrs) = company.accounts.create!(name: name, **attrs)
  def people(acct) = Contact.where(account_id: acct.id).order(:id).pluck(:first_name, :last_name, :is_primary)

  it 'makes the primary contact from the account, with its email, phone and address' do
    acct = account('Jeretta Smuts', email: 'j@example.com', phone: '2605550100', billing_city: 'Goshen')
    expect(described_class.ensure!(acct).status).to eq(:created)

    contact = Contact.find_by(account_id: acct.id)
    expect([contact.first_name, contact.last_name, contact.email, contact.city, contact.is_primary])
      .to eq(['Jeretta', 'Smuts', 'j@example.com', 'Goshen', true])
  end

  it 'makes two people from "John & Mary Smith"' do
    acct = account('John & Mary Smith')
    described_class.ensure!(acct)
    expect(people(acct)).to eq([['John', 'Smith', true], ['Mary', 'Smith', false]])
  end

  it 'skips names that are not plainly a person' do
    ['Smith Family', 'Smith, John', 'Acme Homes LLC', 'Lot 12'].each do |name|
      acct = account(name)
      result = described_class.ensure!(acct)
      expect(result.status).to eq(:skipped), name
      expect(people(acct)).to be_empty
    end
  end

  it 'leaves an account that already has a contact alone' do
    acct = account('Ben Ray')
    company.contacts.create!(first_name: 'Ben', account: acct)
    expect(described_class.ensure!(acct).reason).to eq('already has a contact')
  end

  it 'does nothing for a business-to-business company' do
    company.update!(industry: 'saas')
    acct = account('Jeretta Smuts')
    expect(described_class.ensure!(acct).status).to eq(:skipped)
    expect(people(acct)).to be_empty
  end
end
