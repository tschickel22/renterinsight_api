# frozen_string_literal: true

require 'rails_helper'

# A dealer cannot set up an agreement package themselves, so the message
# says whom to contact instead of sending them looking for a screen.
RSpec.describe Agreements::FromDealSheet, '#check' do
  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)}") }
  let(:user) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Sale', contact_id: buyer.id) }

  it 'tells the dealer to contact support when no package is set up' do
    blocking = described_class.new(deal, user: user).check[:blocking]
    brand = Brand.current(company: company)
    expect(blocking).to include(
      "Your agreement package is not set up yet. Contact #{brand.name} to set it up: #{brand.support_email} or 303-586-4420."
    )
  end
end
