# frozen_string_literal: true

require 'rails_helper'

# The customer hears about a phase only when the dealer said so: the phase's
# "notify client on start/complete" switch, a phase and project the client can
# see, and once per phase. Production sent 43 "has started" emails for phases
# whose start switch was off, mostly from checking off a phase's first step.
RSpec.describe ProjectNotificationService, '.notify_phase_change client fallback', type: :service do
  let(:company) { create(:company) }
  let(:project) do
    company.projects.create!(name: 'Diaz home', status: 'active', customer_name: 'Ana Diaz',
                             customer_email: 'ana@example.com', client_visible: true)
  end

  def phase!(attrs = {})
    project.project_phases.create!({ company: company, name: 'Set', position: 0, status: 'not_started',
                                     visible_to_client: true, notify_client_on_start: false,
                                     notify_client_on_complete: true }.merge(attrs))
  end

  before { allow(CommunicationService).to receive(:send_email).and_return(double(id: 1)) }

  it 'does not email the customer when a phase starts and its start switch is off' do
    phase = phase!
    phase.update!(status: 'in_progress', started_at: Time.current) # what checking off the first step does

    expect(CommunicationService).not_to have_received(:send_email)
  end

  it 'emails once when the start switch is on, and not again when the phase is reopened' do
    phase = phase!(notify_client_on_start: true)
    phase.update!(status: 'in_progress')
    phase.update!(status: 'not_started')
    phase.update!(status: 'in_progress')

    expect(CommunicationService).to have_received(:send_email).once
    expect(phase.reload.client_notified_start).to be(true)
  end

  it 'emails on completion when that switch is on, with no dashes in the subject' do
    phase = phase!(status: 'in_progress')
    phase.mark_complete!

    expect(CommunicationService).to have_received(:send_email)
      .with(hash_including(to: 'ana@example.com', subject: 'Diaz home: Set is complete!')).once
  end

  it 'stays quiet for a hidden phase or a project the client cannot see' do
    phase!(visible_to_client: false, status: 'in_progress').mark_complete!
    project.update!(client_visible: false)
    phase!(name: 'Trim', position: 1, status: 'in_progress').mark_complete!

    expect(CommunicationService).not_to have_received(:send_email)
  end
end
