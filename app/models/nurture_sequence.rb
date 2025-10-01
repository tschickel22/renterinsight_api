class NurtureSequence < ApplicationRecord
  has_many :nurture_steps, dependent: :destroy
  has_many :steps, class_name: 'NurtureStep', dependent: :destroy
  has_many :nurture_enrollments, dependent: :delete_all
end
