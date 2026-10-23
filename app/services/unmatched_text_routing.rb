# frozen_string_literal: true

# Who a text to a dealer's own or provisioned number belongs to when it is not
# a reply to anything we sent and the sender is nobody in the CRM: one person,
# or a rotation between reps. Saved per company in Settings
# ('Company', id, KEY). The rotation is a RoundRobinAssignmentList, the kind
# intake forms, plays and workflows use, kept in place so it holds its turn.
#
# Unset (or nobody left active), the new lead is unassigned and the company's
# admins are told, so a cold text never sits where nobody looks.
class UnmatchedTextRouting
  KEY = 'sms_unmatched_texts'
  MODES = %w[user round_robin].freeze

  attr_reader :company

  def initialize(company)
    @company = company
  end

  def config
    @config ||= (Setting.get('Company', company.id, KEY, {}) || {}).to_h.stringify_keys
  end

  def mode = config['mode'].presence
  def user_id = config['user_id'].presence&.to_i

  def rotation
    return nil unless mode == 'round_robin' && config['round_robin_list_id'].present?

    lists.find_by(id: config['round_robin_list_id'])
  end

  # The owner for one new lead. Advances the rotation, so call it once per
  # lead actually created. The one person, if set, is also the rotation's
  # stand-in when every rep in it is inactive.
  def next_owner_id
    picked = rotation&.next_active_user!&.id
    picked || (user_id if company.users.where(id: user_id, status: 'active').exists?)
  end

  # mode: 'user' or 'round_robin' (blank clears); user_id: the one person (or
  # the rotation's stand-in); rotation_user_ids: the reps to rotate between.
  def save!(mode:, user_id: nil, rotation_user_ids: [])
    mode = mode.presence
    raise ArgumentError, 'Choose one person or a rotation' if mode && !MODES.include?(mode)

    active = company.users.where(status: 'active')
    user_id = user_id.presence&.to_i
    raise ArgumentError, 'Choose someone at this dealership' if user_id && !active.exists?(id: user_id)
    raise ArgumentError, 'Choose who gets these texts' if mode == 'user' && user_id.nil?

    value = { 'mode' => mode, 'user_id' => user_id }
    if mode == 'round_robin'
      ids = Array(rotation_user_ids).map(&:to_i).select(&:positive?).uniq
      ids &= active.where(id: ids).pluck(:id)
      raise ArgumentError, 'Choose at least one active rep to rotate between' if ids.empty?

      list = rotation || lists.find_by(id: config['round_robin_list_id'])
      if list
        list.update!(user_ids: ids, active: true)
      else
        list = lists.create!(name: unique_list_name, user_ids: ids, active: true)
      end
      value['round_robin_list_id'] = list.id
    elsif config['round_robin_list_id'].present?
      # Kept, so switching back to a rotation picks up the same reps and turn.
      value['round_robin_list_id'] = config['round_robin_list_id']
    end
    Setting.set('Company', company.id, KEY, value.compact)
    @config = nil
    self
  end

  def as_json(*)
    { mode: mode, user_id: user_id, rotation_user_ids: Array(rotation&.user_ids).map(&:to_i) }
  end

  private

  def lists = RoundRobinAssignmentList.where(company_id: company.id)

  def unique_list_name
    taken = lists.pluck(:name)
    name = base = 'Text message rotation'
    n = 1
    name = "#{base} (#{n += 1})" while taken.include?(name)
    name
  end
end
