# frozen_string_literal: true

require 'rails_helper'

# email_invalid describes ONE address. When a rep replaces the address the flag has to be
# released, or correcting a typo leaves the record permanently unmailable and the fix looks
# like it did nothing.
RSpec.describe 'email_invalid lifecycle' do
  let(:company) { Company.create!(name: "EI-#{SecureRandom.hex(4)}") }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }

  def make_lead(attrs = {})
    Lead.create!({
      company: company, source: source,
      first_name: 'A', last_name: 'B',
      email: "lead#{SecureRandom.hex(4)}@e.com", status: 'new'
    }.merge(attrs))
  end

  describe Lead do
    it 'clears the flag when the address is corrected' do
      lead = make_lead
      lead.update_column(:email_invalid, true)

      lead.reload.update!(email: 'corrected@example.com')

      expect(lead.reload.email_invalid).to be(false)
    end

    it 'keeps the flag when an unrelated attribute changes' do
      lead = make_lead
      lead.update_column(:email_invalid, true)

      lead.reload.update!(first_name: 'Renamed')

      expect(lead.reload.email_invalid).to be(true)
    end

    # A create sets email from nil, which counts as a change. Without the persisted? guard
    # that would wipe the flag on any record imported as already-bad.
    it 'does not clear a flag set explicitly at creation' do
      lead = make_lead(email_invalid: true)
      expect(lead.reload.email_invalid).to be(true)
    end
  end

  describe Contact do
    let(:account) do
      Account.create!(company: company, name: "Acct-#{SecureRandom.hex(4)}")
    end

    def make_contact(attrs = {})
      Contact.create!({
        company: company, account: account,
        first_name: 'A', last_name: 'B',
        email: "c#{SecureRandom.hex(4)}@e.com"
      }.merge(attrs))
    end

    it 'clears the flag when the address is corrected' do
      contact = make_contact
      contact.update_column(:email_invalid, true)

      contact.reload.update!(email: 'corrected@example.com')

      expect(contact.reload.email_invalid).to be(false)
    end

    it 'keeps the flag when an unrelated attribute changes' do
      contact = make_contact
      contact.update_column(:email_invalid, true)

      contact.reload.update!(first_name: 'Renamed')

      expect(contact.reload.email_invalid).to be(true)
    end
  end
end
