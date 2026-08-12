require 'rails_helper'

# Intake form alerts are addressed to a staff member but filed on the lead's
# record. Left visible they made the lead's Communication Center read as
# correspondence with the customer, and a rep opening his own alert registered
# as the customer opening email, which pushed that lead to the top of the
# "Opened Email Today" workqueue.
#
# These cover the shared predicate all three consumers now use, and in
# particular that it leaves genuine customer mail alone.
RSpec.describe Communication, type: :model do
  let(:company) { create(:company) }
  let(:lead) do
    create(:lead, company: company, email: 'customer@example.com', phone: '555-867-5309')
  end

  def scoped
    described_class.where(communicable: lead)
                   .without_internal_notifications(
                     email_expression: described_class.connection.quote(lead.email),
                     phone_expression: described_class.connection.quote(lead.phone)
                   )
  end

  def build_comm(**attrs)
    create(
      :communication,
      {
        communicable: lead,
        company: company,
        direction: 'outbound',
        channel: 'email',
        to_address: 'rep@dealership.com',
        metadata: { 'category' => 'system', 'source' => 'intake_form' }
      }.merge(attrs)
    )
  end

  describe '.without_internal_notifications' do
    it 'hides an intake alert addressed to a rep' do
      comm = build_comm
      expect(scoped).not_to include(comm)
    end

    it 'keeps a system email that did reach the customer' do
      comm = build_comm(to_address: ' Customer@Example.com ')
      expect(scoped).to include(comm)
    end

    it 'keeps ordinary correspondence even when it went elsewhere' do
      comm = build_comm(metadata: { 'category' => 'transactional' }, to_address: 'someone@else.com')
      expect(scoped).to include(comm)
    end

    it 'keeps mail carrying no category at all' do
      comm = build_comm(metadata: {}, to_address: 'someone@else.com')
      expect(scoped).to include(comm)
    end

    it 'keeps inbound mail' do
      comm = build_comm(direction: 'inbound')
      expect(scoped).to include(comm)
    end

    it 'ignores country code and formatting when comparing SMS recipients' do
      comm = build_comm(channel: 'sms', to_address: '+15558675309')
      expect(scoped).to include(comm)
    end

    it 'hides an SMS alert sent to a different number' do
      comm = build_comm(channel: 'sms', to_address: '+15550001111')
      expect(scoped).not_to include(comm)
    end

    context 'when the lead has no address on file' do
      let(:lead) { create(:lead, company: company, email: nil, phone: nil) }

      it 'hides a system email, since the lead cannot have received it' do
        comm = build_comm
        expect(scoped).not_to include(comm)
      end
    end
  end

  describe '.internal_notifications' do
    it 'is the exact complement of the exclusion scope' do
      internal = build_comm
      customer = build_comm(to_address: lead.email)

      matched = described_class.where(communicable: lead).internal_notifications(
        email_expression: described_class.connection.quote(lead.email),
        phone_expression: described_class.connection.quote(lead.phone)
      )

      expect(matched).to include(internal)
      expect(matched).not_to include(customer)
      expect(scoped).to include(customer)
      expect(scoped).not_to include(internal)
    end
  end
end
