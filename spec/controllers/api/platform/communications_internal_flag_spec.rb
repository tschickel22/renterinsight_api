require 'rails_helper'

# Intake form alerts are addressed to a staff member but filed on the lead's
# timeline, so the lead's Communication Center read as though we had emailed the
# customer. These cover the flag that lets the UI say otherwise, and in
# particular that it stays off for genuine customer mail.
RSpec.describe Api::Platform::CommunicationsController, type: :controller do
  let(:lead) do
    Lead.new(email: 'alcinadominick@gmail.com', phone: '(555) 867-5309')
  end

  def flag_for(comm, entity: lead)
    controller.instance_variable_set(:@entity, entity)
    controller.send(:internal_notification?, comm)
  end

  # Built as a plain object rather than a Communication so the local text
  # metadata column (jsonb on the deployed databases) cannot quietly turn the
  # hash into a string and make these pass or fail for the wrong reason.
  CommRow = Struct.new(:direction, :channel, :to_address, :metadata, keyword_init: true)

  def build_comm(**attrs)
    CommRow.new(
      {
        direction: 'outbound',
        channel: 'email',
        to_address: 'reid@evangelinehomecenter.com',
        metadata: { 'category' => 'system', 'source' => 'intake_form' }
      }.merge(attrs)
    )
  end

  it 'flags an intake alert addressed to a rep' do
    expect(flag_for(build_comm)).to be true
  end

  it 'leaves a system email addressed to the customer unflagged' do
    comm = build_comm(to_address: 'AlcinaDominick@gmail.com ')
    expect(flag_for(comm)).to be false
  end

  it 'leaves ordinary correspondence unflagged even when it goes elsewhere' do
    comm = build_comm(metadata: { 'category' => 'transactional' }, to_address: 'someone@else.com')
    expect(flag_for(comm)).to be false
  end

  it 'flags a system email when the lead has no address to compare against' do
    expect(flag_for(build_comm, entity: Lead.new(email: nil))).to be true
  end

  it 'ignores country code and formatting when comparing SMS recipients' do
    comm = build_comm(channel: 'sms', to_address: '+15558675309')
    expect(flag_for(comm)).to be false
  end

  it 'flags an SMS alert sent to a different number' do
    comm = build_comm(channel: 'sms', to_address: '+15550001111')
    expect(flag_for(comm)).to be true
  end

  it 'reads metadata stored as a JSON string' do
    comm = build_comm(metadata: '{"category":"system","source":"intake_form"}')
    expect(flag_for(comm)).to be true
  end

  it 'leaves inbound mail unflagged' do
    comm = build_comm(direction: 'inbound', to_address: 'reid@evangelinehomecenter.com')
    expect(flag_for(comm)).to be false
  end
end
