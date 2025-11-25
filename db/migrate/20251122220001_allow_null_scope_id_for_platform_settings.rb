# frozen_string_literal: true

class AllowNullScopeIdForPlatformSettings < ActiveRecord::Migration[8.0]
  def up
    # Allow scope_id to be null for platform-level settings
    change_column_null :settings, :scope_id, true
    
    puts "✅ Settings table updated to allow null scope_id for platform settings"
  end

  def down
    # Note: This rollback might fail if there are platform settings with null scope_id
    change_column_null :settings, :scope_id, false
  end
end
