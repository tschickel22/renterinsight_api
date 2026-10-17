# frozen_string_literal: true

# Default assignments a project template hands to the project built from it (E69).
#
# Each task takes its own default, then its phase's, then the template's. The
# most specific default that is set wins even when it cannot be used: an
# inactive or deleted contractor or employee leaves the item unassigned and is
# listed in #issues, rather than quietly falling back to someone else or
# failing the build.
class ProjectTemplateAssignmentResolver
  attr_reader :issues

  def initialize(template, company)
    @template = template
    @company = company
    @issues = []
    @issue_index = {}
    @vendors = {}
    @users = {}
  end

  # level: :template, :phase (template_phase) or :task (template_phase, task)
  # task is a ProjectTemplatePhaseTask or a default_tasks hash.
  def vendor_id(level, template_phase = nil, task = nil)
    id, source = pick(level, template_phase, task, :default_vendor_id)
    return nil unless id

    vendor = usable_vendor(id)
    return vendor.id if vendor

    flag('contractor', id, source, template_phase, task)
    nil
  end

  def user_id(level, template_phase = nil, task = nil)
    id, source = pick(level, template_phase, task, :default_assigned_to_id)
    return nil unless id

    user = usable_user(id)
    return user.id if user

    flag('employee', id, source, template_phase, task)
    nil
  end

  def assign_contractor!(phase_task, vendor_id, assigned_by:)
    return unless vendor_id

    phase_task.contractor_assignments.create!(
      contractor: @vendors[vendor_id],
      company: @company,
      assigned_by: assigned_by,
      status: 'assigned',
      assigned_at: Time.current
    )
  end

  private

  def pick(level, template_phase, task, field)
    candidates = []
    candidates << [task_value(task, field), :task] if level == :task
    candidates << [template_phase&.public_send(field), :phase] if level.in?(%i[task phase])
    candidates << [@template.public_send(field), :template]
    candidates.find { |value, _| value.present? }&.then { |value, source| [value.to_i, source] }
  end

  def task_value(task, field)
    return nil if task.nil?
    return task.public_send(field) if task.respond_to?(field)

    task.with_indifferent_access[field] if task.respond_to?(:with_indifferent_access)
  end

  # A template may only name this company's own contractors, so look up through
  # the company: another tenant's vendor id resolves to nothing.
  def usable_vendor(id)
    @vendors.fetch(id) { @vendors[id] = @company.contractors.active.find_by(id: id) }
  end

  def usable_user(id)
    @users.fetch(id) { @users[id] = @company.users.active.find_by(id: id) }
  end

  # One entry per default that could not be used, counting the items it left unassigned.
  def flag(kind, id, source, template_phase, task)
    key = [kind, id, source, source == :template ? nil : template_phase&.id, source == :task ? task_key(task) : nil]
    if (entry = @issue_index[key])
      entry['item_count'] += 1
      return
    end

    record = kind == 'contractor' ? @company.vendors.find_by(id: id) : @company.users.find_by(id: id)
    entry = {
      'kind' => kind,
      'id' => id,
      'name' => record ? display_name(record) : nil,
      'reason' => reason_for(record),
      'source' => source.to_s,
      'phase_name' => source == :template ? nil : template_phase&.name,
      'task_name' => source == :task ? task_name(task) : nil,
      'item_count' => 1
    }
    @issue_index[key] = entry
    @issues << entry
  end

  def reason_for(record)
    return 'not_found' if record.nil?
    return 'deleted' if record.respond_to?(:is_deleted) && record.is_deleted
    return 'not_a_contractor' if record.is_a?(Vendor) && record.vendor_type != 'contractor'

    'inactive'
  end

  def display_name(record)
    return record.name if record.is_a?(Vendor)

    [record.first_name, record.last_name].compact_blank.join(' ').presence || record.email
  end

  def task_name(task)
    task.respond_to?(:name) ? task.name : (task[:title] || task[:name] || task['title'] || task['name'])
  end

  def task_key(task)
    task.respond_to?(:id) ? task.id : task.object_id
  end
end
