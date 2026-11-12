# frozen_string_literal: true

# Photos, videos and files on a project, phase or sub-task, seen by the buyer
# and the contractor when the dealer allows it (E102).
#
# client_visible / contractor_visible are nullable on purpose: nil follows the
# rule (the phase or project "Share photos with the buyer" setting, and
# photos and videos to the contractor), true or false is the dealer's own
# choice for that one file and wins over the setting.
class AddProjectMediaSharing < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_column :project_documents, :client_visible, :boolean
    add_column :project_documents, :contractor_visible, :boolean
    add_column :project_documents, :source, :string, default: 'dealer', null: false
    add_column :project_documents, :vendor_id, :bigint
    add_column :project_documents, :contractor_assignment_id, :bigint
    add_index :project_documents, :contractor_assignment_id, algorithm: :concurrently

    add_column :projects, :share_media_with_client, :boolean, default: false, null: false
    # nil follows the project setting.
    add_column :project_phases, :share_media_with_client, :boolean
  end
end
