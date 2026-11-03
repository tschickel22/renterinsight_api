# frozen_string_literal: true

# These three are company-tier roles, which get every location, but their text
# said assigned locations. Wording only; no access changes.
class CorrectCompanyRoleDescriptions < ActiveRecord::Migration[8.0]
  TEXT = {
    'company_manager' => ['Operational control with assigned region/location access', 'Operational control across every location'],
    'company_staff' => ['Standard user with assigned location access', 'Standard user with access to every location'],
    'company_read_only' => ['View-only access to assigned areas', 'View-only access across every location']
  }.freeze

  def up
    TEXT.each do |key, (old_text, new_text)|
      execute "UPDATE roles SET description = #{connection.quote(new_text)} WHERE key = #{connection.quote(key)} AND company_id IS NULL AND description = #{connection.quote(old_text)}"
    end
  end

  def down
    TEXT.each do |key, (old_text, new_text)|
      execute "UPDATE roles SET description = #{connection.quote(old_text)} WHERE key = #{connection.quote(key)} AND company_id IS NULL AND description = #{connection.quote(new_text)}"
    end
  end
end
