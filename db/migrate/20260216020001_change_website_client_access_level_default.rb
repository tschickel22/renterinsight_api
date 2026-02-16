class ChangeWebsiteClientAccessLevelDefault < ActiveRecord::Migration[8.0]
  def up
    # Change default from 0 (no access) to 3 (full editor)
    # so new websites are usable by company admins out of the box
    change_column_default :websites, :client_access_level, from: 0, to: 3

    # Update all existing websites from 0 to 3
    execute "UPDATE websites SET client_access_level = 3 WHERE client_access_level = 0"
  end

  def down
    change_column_default :websites, :client_access_level, from: 3, to: 0
  end
end
