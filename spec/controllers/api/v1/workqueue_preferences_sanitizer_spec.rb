# frozen_string_literal: true

require 'rails_helper'

# hidden_queues is filtered against an allowlist before being stored. When a
# queue is missing from that allowlist the user's change is silently dropped —
# they uncheck a queue, see "Preferences saved", and it's still in the sidebar
# after reload. The allowlist is derived from WorkqueueService::QUEUES so that
# can't drift; these specs pin that behavior.
RSpec.describe Api::V1::UserSettingsController, type: :controller do
  subject(:sanitize) { controller.send(:sanitize_workqueue_preferences, raw) }

  describe 'hidden_queues' do
    context 'with every queue the sidebar can show' do
      let(:raw) { { hidden_queues: WorkqueueService::GROUPS.flat_map { |g| g[:queue_ids] } } }

      it 'keeps all of them' do
        expect(sanitize[:hidden_queues]).to match_array(WorkqueueService::GROUPS.flat_map { |g| g[:queue_ids] })
      end
    end

    context 'with the contact engagement queues' do
      let(:raw) do
        { hidden_queues: %w[engagement_contact_opened_today engagement_contact_opened_week
                            engagement_contact_clicked_today] }
      end

      it 'keeps them' do
        expect(sanitize[:hidden_queues]).to match_array(raw[:hidden_queues])
      end
    end

    context 'with an unknown queue id' do
      let(:raw) { { hidden_queues: %w[leads_mine not_a_real_queue] } }

      it 'drops only the unknown one' do
        expect(sanitize[:hidden_queues]).to eq(%w[leads_mine])
      end
    end
  end

  describe 'thresholds' do
    let(:raw) { { new_leads_days: '999999', stale_deals_days: '0', tasks_week_days: 7 } }

    it 'clamps out-of-range values to 1..365' do
      expect(sanitize[:new_leads_days]).to eq(365)
      expect(sanitize[:stale_deals_days]).to eq(1)
      expect(sanitize[:tasks_week_days]).to eq(7)
    end
  end

  # The Preferences UI builds its checkbox list from the summary, which is built
  # from GROUPS. A queue listed there but absent from QUEUES would render a
  # checkbox that can never be saved.
  it 'exposes no grouped queue that is missing from QUEUES' do
    grouped = WorkqueueService::GROUPS.flat_map { |g| g[:queue_ids] }
    expect(grouped - WorkqueueService::QUEUES.keys).to be_empty
  end
end
