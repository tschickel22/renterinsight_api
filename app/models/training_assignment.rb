# frozen_string_literal: true

# A training video a company requires one of its people to watch (E88).
# Done when the person's view of it is completed; nothing is stored twice.
class TrainingAssignment < ApplicationRecord
  # Company setting: video ids every new user of the company is given.
  NEW_USER_SETTING = 'training_required_for_new_users'

  belongs_to :user
  belongs_to :training_video

  validates :company_id, presence: true
  validates :training_video_id, uniqueness: { scope: :user_id }

  def self.new_user_video_ids(company_id)
    Array(Setting.get('Company', company_id, NEW_USER_SETTING, [])).map(&:to_i)
  end

  # Gives a new person the company's required videos.
  def self.assign_new_user!(user)
    return if user.company_id.blank?

    ids = TrainingVideo.published.where(id: new_user_video_ids(user.company_id)).pluck(:id)
    ids.each do |video_id|
      create_with(company_id: user.company_id, source: 'new_user').find_or_create_by!(user_id: user.id, training_video_id: video_id)
    end
  rescue StandardError => e
    Rails.logger.warn("[TrainingAssignment] new user #{user.id}: #{e.class} #{e.message}")
  end
end
