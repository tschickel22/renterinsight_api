require 'rails_helper'

# Project emails and texts go to the vendor contacts ticked "Gets project
# emails"; a vendor with none ticked keeps using its own email and phone.
RSpec.describe ProjectNotificationService, 'vendor contacts', type: :service do
  let(:company) { create(:company) }

  let(:contractor) do
    Contractor.create!(company: company, name: 'MHI Installers', contact_name: 'Front Desk',
                       email: 'office@mhi.example', phone: '3525550100', vendor_type: 'contractor',
                       status: 'active', sms_opt_in: true, sms_consent_source: 'dealer_recorded')
  end

  let(:ticket) do
    ServiceTicket.create!(company: company, title: 'punchlist', description: 'Punch list', status: 'open', priority: 'medium')
  end

  let(:assignment) do
    ContractorAssignment.skip_callback(:commit, :after, :notify_on_assignment, raise: false)
    a = ContractorAssignment.create!(contractor: contractor, assignable: ticket, company: company,
                                     status: 'assigned', assigned_at: Time.current, notified_at: 1.hour.ago)
    ContractorAssignment.set_callback(:commit, :after, :notify_on_assignment)
    a
  end

  def add_contact(**attrs)
    contractor.vendor_contacts.create!({ company: company }.merge(attrs))
  end

  before do
    allow(CommunicationService).to receive(:send_email).and_return(double(id: 111))
    allow(CommunicationService).to receive(:send_sms).and_return(double(id: 222))
  end

  it 'uses the vendor email and phone when no contact is ticked' do
    add_contact(first_name: 'Ann', email: 'ann@mhi.example')

    described_class.resend_assignment_notification(assignment)

    expect(CommunicationService).to have_received(:send_email).once.with(hash_including(to: 'office@mhi.example'))
    expect(CommunicationService).to have_received(:send_sms).once.with(hash_including(to: '3525550100'))
  end

  it 'emails every ticked contact and none of the others' do
    add_contact(first_name: 'Ann', email: 'ann@mhi.example', receives_project_notices: true)
    add_contact(first_name: 'Bob', email: 'bob@mhi.example', receives_project_notices: true)
    add_contact(first_name: 'Cal', email: 'cal@mhi.example')

    result = described_class.resend_assignment_notification(assignment)

    expect(CommunicationService).to have_received(:send_email).twice
    expect(CommunicationService).to have_received(:send_email).with(hash_including(to: 'ann@mhi.example'))
    expect(CommunicationService).to have_received(:send_email).with(hash_including(to: 'bob@mhi.example'))
    expect(result[:email][:to]).to eq('ann@mhi.example, bob@mhi.example')
  end

  it 'texts only ticked contacts who consented, never the vendor phone instead' do
    texter = add_contact(first_name: 'Ann', phone: '3525550111', receives_project_notices: true)
    texter.record_sms_consent!(opted_in: true, source: 'dealer_recorded', note: 'said yes on site')
    add_contact(first_name: 'Bob', phone: '3525550122', receives_project_notices: true)

    described_class.resend_assignment_notification(assignment)

    expect(CommunicationService).to have_received(:send_sms).once.with(hash_including(to: '3525550111'))
  end

  it 'reports no consent when ticked contacts have phones but none opted in' do
    add_contact(first_name: 'Bob', email: 'bob@mhi.example', phone: '3525550122', receives_project_notices: true)

    result = described_class.resend_assignment_notification(assignment)

    expect(CommunicationService).not_to have_received(:send_sms)
    expect(result[:sms][:reason]).to eq('Contractor has not opted in to SMS')
  end

  it 'greets one recipient by name and several by company' do
    add_contact(first_name: 'Ann', last_name: 'Lee', email: 'ann@mhi.example', receives_project_notices: true)
    expect(described_class.send(:notice_greeting, contractor.reload)).to eq('Ann Lee')

    add_contact(first_name: 'Bob', email: 'bob@mhi.example', receives_project_notices: true)
    expect(described_class.send(:notice_greeting, contractor.reload)).to eq('MHI Installers')
  end

  it 'ignores deleted contacts' do
    gone = add_contact(first_name: 'Ann', email: 'ann@mhi.example', receives_project_notices: true)
    gone.soft_delete!

    described_class.resend_assignment_notification(assignment)

    expect(CommunicationService).to have_received(:send_email).once.with(hash_including(to: 'office@mhi.example'))
  end
end

RSpec.describe VendorContact, type: :model do
  let(:company) { create(:company) }
  let(:vendor) { Vendor.create!(company: company, name: 'Triad Financial', vendor_type: 'service_provider') }

  it 'keeps one primary per vendor' do
    a = vendor.vendor_contacts.create!(first_name: 'A', is_primary: true)
    b = vendor.vendor_contacts.create!(first_name: 'B', is_primary: true)

    expect(a.reload.is_primary).to be false
    expect(b.reload.is_primary).to be true
    expect(b.company_id).to eq(company.id)
  end

  it 'needs a name, email or phone' do
    expect(vendor.vendor_contacts.build).not_to be_valid
  end

  it 'refuses consent without a source' do
    c = vendor.vendor_contacts.create!(first_name: 'A', phone: '3525550100')
    expect { c.record_sms_consent!(opted_in: true) }.to raise_error(ArgumentError)
  end
end
