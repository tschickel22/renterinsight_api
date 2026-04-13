# frozen_string_literal: true

class WorkqueueActivity < ApplicationRecord
  self.table_name  = 'workqueue_activities'
  self.primary_key = 'uid'

  def readonly?
    true
  end

  before_save    { raise ActiveRecord::ReadOnlyRecord }
  before_destroy { raise ActiveRecord::ReadOnlyRecord }
end
