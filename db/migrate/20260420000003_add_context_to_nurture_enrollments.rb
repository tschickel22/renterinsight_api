# frozen_string_literal: true

class AddContextToNurtureEnrollments < ActiveRecord::Migration[8.0]
  def change
    add_column :nurture_enrollments, :context, :jsonb, default: {}
  end
end
