# frozen_string_literal: true

# Picks the next intent_category for a scheduled post. Round-robin over the
# rotation, remembering the last intent used so we advance one step each run.
class ScheduleIntentPicker
  def self.next(rotation:, last: nil)
    rotation = Array(rotation).map(&:to_s).reject(&:blank?)
    return 'education' if rotation.empty?

    return rotation.first if last.blank? || !rotation.include?(last.to_s)

    idx = rotation.index(last.to_s) + 1
    rotation[idx % rotation.length]
  end
end
