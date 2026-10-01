# frozen_string_literal: true

require 'rails_helper'

# SendCommunicationJob sends a Communication that already exists (scheduled
# or background sends) through CommunicationService.send_existing_communication.
RSpec.describe SendCommunicationJob, type: :job do
  let(:lead) { create(:lead) }
  let(:communication) { create(:communication, communicable: lead, status: 'pending', provider: 'smtp') }

  describe '#perform' do
    it 'sends it and logs the provider' do
      allow(CommunicationService).to receive(:send_existing_communication).with(communication, {})
                                                                         .and_return({ success: true, provider: 'smtp' })
      allow(Rails.logger).to receive(:info)

      described_class.new.perform(communication.id)

      expect(Rails.logger).to have_received(:info).with(/Successfully sent communication #{communication.id} via smtp/)
    end

    it 'passes options through' do
      expect(CommunicationService).to receive(:send_existing_communication).with(communication, { test: 'value' })
                                                                          .and_return({ success: true, provider: 'smtp' })

      described_class.new.perform(communication.id, { test: 'value' })
    end

    it 'marks it failed and raises so the job retries' do
      allow(CommunicationService).to receive(:send_existing_communication)
        .and_return({ success: false, error: 'Provider error' })

      expect { described_class.new.perform(communication.id) }.to raise_error(StandardError, 'Provider error')
      expect(communication.reload.status).to eq('failed')
    end

    it 'skips one already sent' do
      communication.update!(status: 'sent', sent_at: Time.current)
      expect(CommunicationService).not_to receive(:send_existing_communication)

      described_class.new.perform(communication.id)
    end

    it 'does nothing for a communication that no longer exists' do
      expect { described_class.new.perform(0) }.not_to raise_error
    end

    # Communication had a user_id column but no user association, and the
    # service reads communication.user after every email send, so this path
    # crashed on success and again in its own error handler.
    it 'sends an email end to end without crashing on the sender lookup' do
      allow_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
        .and_return({ success: true, external_id: 'msg_1' })

      expect { described_class.new.perform(communication.id) }.not_to raise_error
      expect(communication.reload.external_id).to eq('msg_1')
    end
  end
end
