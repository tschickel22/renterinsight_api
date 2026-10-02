# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Project, '#set_phase_status!' do
  let(:company) { Company.create!(name: 'Phase Co', industry: 'manufactured_housing') }
  let(:project) { company.projects.create!(name: 'Diaz home', status: 'active', customer_name: 'Ana Diaz') }
  let!(:phase) do
    project.project_phases.create!(company: company, name: 'Home Arrives', position: 0, status: 'not_started')
  end

  it 'never records a completion before the start when completing straight from not started' do
    project.set_phase_status!(phase, 'completed')
    phase.reload

    expect(phase.status).to eq('completed')
    expect(phase.started_at).to eq(phase.completed_at)
  end

  it 'keeps an earlier start time' do
    started = 3.days.ago.change(usec: 0)
    phase.update!(status: 'in_progress', started_at: started)
    project.set_phase_status!(phase, 'completed')

    expect(phase.reload.started_at).to eq(started)
    expect(phase.completed_at).to be > started
  end
end
