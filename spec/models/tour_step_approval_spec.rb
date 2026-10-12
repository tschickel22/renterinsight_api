# frozen_string_literal: true

require 'rails_helper'

# A tour reaches dealers only after a person has played and approved it, so a
# change to its steps by any path (the Tours admin, the Knowledge admin API, a
# publish) sends it back for approval. The automated check does not.
RSpec.describe TourStep do
  let(:approver) { User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", password: 'Password123!', first_name: 'A', last_name: 'B', role: 'platform_admin', status: 'active') }
  let(:tour) { Tour.create!(key: "t-#{SecureRandom.hex(3)}", name: 'T', trigger_type: 'manual') }
  let!(:step) { tour.steps.create!(position: 1, title: 'One', content: 'Original', selector: '[data-tour="a"]', placement: 'bottom', highlight_type: 'outline') }

  before { tour.update!(approved_at: Time.current, approved_by_id: approver.id) }

  it 'clears the approval when a step is edited' do
    step.update!(content: 'Changed')
    expect(tour.reload.approved_at).to be_nil
    expect(tour.approved_by_id).to be_nil
  end

  it 'clears it when a step is added or removed' do
    tour.steps.create!(position: 2, title: 'Two', content: 'Added', selector: '#x', placement: 'bottom', highlight_type: 'outline')
    expect(tour.reload.approved_at).to be_nil

    tour.update!(approved_at: Time.current)
    step.destroy!
    expect(tour.reload.approved_at).to be_nil
  end

  it 'clears both tours when a step moves to another one' do
    other = Tour.create!(key: "o-#{SecureRandom.hex(3)}", name: 'O', trigger_type: 'manual', approved_at: Time.current)
    step.update!(tour_id: other.id, position: 5)
    expect(tour.reload.approved_at).to be_nil
    expect(other.reload.approved_at).to be_nil
  end

  it 'keeps the approval when only the automated check result is written' do
    tour.steps.update_all(check_status: 'found', checked_at: Time.current)
    step.reload.update!(check_status: 'missing')
    expect(tour.reload.approved_at).to be_present
  end
end
