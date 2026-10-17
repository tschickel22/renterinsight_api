# frozen_string_literal: true

require 'rails_helper'

# E69: whole-project and whole-phase assignment, and template defaults.
RSpec.describe ProjectAssignmentService do
  let(:company) { create(:company) }
  let(:actor) { make_user('Pat', 'Manager') }
  let(:installer) { Contractor.create!(company: company, name: 'Smith Set-Up', status: 'active') }
  let(:electrician) { Contractor.create!(company: company, name: 'Volt Electric', status: 'active') }
  let(:crew_lead) { make_user('Cam', 'Crew') }

  before { allow(ContractorAssignmentNotifierJob).to receive_message_chain(:set, :perform_later) }

  def make_user(first, last)
    User.create!(email: "#{first.downcase}-#{SecureRandom.hex(3)}@dealer.example", password: 'password123',
                 first_name: first, last_name: last, company_id: company.id, status: 'active')
  end

  def contractor_names(task)
    task.reload.contractor_assignments.map { |a| a.contractor.name }
  end

  describe 'building a project from a template' do
    let(:template) do
      company.project_templates.create!(name: 'Set-up', default_vendor_id: installer.id, default_assigned_to_id: crew_lead.id)
    end
    let!(:set_phase) do
      template.project_template_phases.create!(
        name: 'Set', position: 0,
        default_tasks: [
          { 'name' => 'Level home' },
          { 'name' => 'Wire meter', 'default_vendor_id' => electrician.id }
        ]
      )
    end

    it 'gives each task its own default, then its phase, then the template' do
      project = template.create_project!(company: company, created_by: actor)
      phase = project.project_phases.first
      level, wire = phase.project_phase_tasks.order(:position).to_a

      expect(project.assigned_vendor_id).to eq(installer.id)
      expect(phase.assigned_vendor_id).to eq(installer.id)
      expect(contractor_names(level)).to eq(['Smith Set-Up'])
      expect(contractor_names(wire)).to eq(['Volt Electric'])
      expect(level.assigned_to_id).to eq(crew_lead.id)
      expect(phase.tasks.find_by(title: 'Level home').assigned_to_id).to eq(crew_lead.id)
      expect(project.assignment_issues).to eq([])
    end

    it 'leaves an inactive default unassigned and flags it instead of failing' do
      electrician.update!(status: 'inactive')

      project = template.create_project!(company: company, created_by: actor)
      wire = project.project_phases.first.project_phase_tasks.find_by(name: 'Wire meter')

      expect(wire.contractor_assignments).to be_empty
      expect(project.assignment_issues).to contain_exactly(
        a_hash_including('kind' => 'contractor', 'name' => 'Volt Electric', 'reason' => 'inactive',
                         'source' => 'task', 'task_name' => 'Wire meter', 'item_count' => 1)
      )
    end

    it "never assigns another company's contractor" do
      theirs = Contractor.create!(company: create(:company), name: 'Not Ours', status: 'active')
      template.update!(default_vendor_id: theirs.id)

      project = template.create_project!(company: company, created_by: actor)

      expect(project.assigned_vendor_id).to be_nil
      expect(ContractorAssignment.where(vendor_id: theirs.id)).to be_empty
      expect(project.assignment_issues.first).to include('reason' => 'not_found', 'source' => 'template')
    end
  end

  describe 'changing a phase owner on a live project' do
    let(:project) { company.projects.create!(name: 'Diaz home', status: 'active') }
    let(:phase) { project.project_phases.create!(company: company, name: 'Set', position: 0, status: 'not_started') }
    let!(:open_task) { phase.project_phase_tasks.create!(company: company, name: 'Level home', position: 0) }
    let!(:own_task) { phase.project_phase_tasks.create!(company: company, name: 'Wire meter', position: 1) }
    let!(:done_task) { phase.project_phase_tasks.create!(company: company, name: 'Pier set', position: 2, status: 'completed') }
    let(:service) { described_class.new(project, actor: actor) }

    before do
      own_task.contractor_assignments.create!(contractor: electrician, company: company, status: 'assigned')
    end

    it 'previews without writing anything' do
      result = service.assign_phase(phase, { vendor: installer }, apply_to_tasks: true, preview: true)

      expect(result.tasks_updated).to eq(1)
      expect(result.tasks_kept).to eq(1)
      expect(result.tasks_started).to eq(1)
      expect(phase.reload.assigned_vendor_id).to be_nil
      expect(open_task.reload.contractor_assignments).to be_empty
    end

    it 'hands unstarted tasks to the new contractor and keeps a deliberate one' do
      service.assign_phase(phase, { vendor: installer }, apply_to_tasks: true)

      expect(phase.reload.assigned_vendor_id).to eq(installer.id)
      expect(contractor_names(open_task)).to eq(['Smith Set-Up'])
      expect(contractor_names(own_task)).to eq(['Volt Electric'])
      expect(done_task.reload.contractor_assignments).to be_empty
    end

    it "replaces the phase's previous contractor, but not one who has started" do
      service.assign_phase(phase, { vendor: installer }, apply_to_tasks: true)
      started = phase.project_phase_tasks.create!(company: company, name: 'Skirting', position: 3)
      started.contractor_assignments.create!(contractor: installer, company: company, status: 'in_progress')
      other_installer = Contractor.create!(company: company, name: 'Ace Homes Install', status: 'active')

      service.assign_phase(phase, { vendor: other_installer }, apply_to_tasks: true)

      expect(contractor_names(open_task)).to eq(['Ace Homes Install'])
      expect(contractor_names(started)).to eq(['Smith Set-Up'])
    end

    it 'changes only the phase when not applied to tasks' do
      service.assign_phase(phase, { vendor: installer, user: crew_lead }, apply_to_tasks: false)

      expect(phase.reload.assigned_to_id).to eq(crew_lead.id)
      expect(open_task.reload.contractor_assignments).to be_empty
      expect(open_task.assigned_to_id).to be_nil
    end

    it 'gives a task added later the phase owners' do
      service.assign_phase(phase, { vendor: installer, user: crew_lead }, apply_to_tasks: false)
      added = phase.project_phase_tasks.create!(company: company, name: 'Steps', position: 4)

      service.inherit_for_new_task!(added)

      expect(contractor_names(added)).to eq(['Smith Set-Up'])
      expect(added.reload.assigned_to_id).to eq(crew_lead.id)
    end

    it 'emails a new owner who got no tasks out of it, and only once' do
      empty = project.project_phases.create!(company: company, name: 'Final', position: 2, status: 'not_started')
      allow(ProjectNotificationService).to receive(:notify_contractor_owner_assigned)

      service.assign_phase(empty, { vendor: installer }, apply_to_tasks: true)
      service.assign_phase(phase, { vendor: installer }, apply_to_tasks: true, preview: true)

      expect(ProjectNotificationService).to have_received(:notify_contractor_owner_assigned)
        .with(installer, project, phase: empty).once
    end

    it 'leaves the owner notice to the task email when tasks were handed over' do
      allow(ProjectNotificationService).to receive(:notify_contractor_owner_assigned)

      service.assign_phase(phase, { vendor: installer }, apply_to_tasks: true)

      expect(ProjectNotificationService).not_to have_received(:notify_contractor_owner_assigned)
    end

    it "refuses another company's user as a task's employee" do
      outsider = User.create!(email: "x-#{SecureRandom.hex(3)}@else.example", password: 'password123',
                              first_name: 'X', last_name: 'Y', company_id: create(:company).id, status: 'active')

      expect(open_task.update(assigned_to_id: outsider.id)).to be(false)
      expect(open_task.errors[:assigned_to_id]).to include('is not a user in this company')
    end

    it 'assigns a whole project through phases still following it' do
      other_phase = project.project_phases.create!(company: company, name: 'Trim', position: 1, status: 'not_started',
                                                   assigned_vendor_id: electrician.id)

      result = service.assign_project({ vendor: installer }, apply_to_phases: true)

      expect(project.reload.assigned_vendor_id).to eq(installer.id)
      expect(phase.reload.assigned_vendor_id).to eq(installer.id)
      expect(other_phase.reload.assigned_vendor_id).to eq(electrician.id)
      expect(result.phases_updated).to eq(1)
    end
  end
end
