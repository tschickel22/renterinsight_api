class CreateWorkqueueDismissals < ActiveRecord::Migration[8.0]
  def change
    create_table :workqueue_dismissals do |t|
      t.references :company, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :entity_type, null: false
      t.bigint :entity_id, null: false

      # The moment the user set this aside. Every queue compares it against the
      # freshness of whatever put the row there, so anything newer than this
      # brings the row back on its own.
      t.datetime :dismissed_at, null: false

      t.timestamps
    end

    # One row per person per record: dismissing again updates when, it does not
    # add another row. Scoped by user because this is a personal inbox, and one
    # rep clearing their queue must not clear it for everyone else.
    add_index :workqueue_dismissals,
              %i[user_id entity_type entity_id],
              unique: true,
              name: 'index_workqueue_dismissals_on_user_and_entity'

    # Supports the per-queue lookup: filter by user and entity type, then
    # compare dismissed_at against each row's freshness.
    add_index :workqueue_dismissals,
              %i[user_id entity_type dismissed_at],
              name: 'index_workqueue_dismissals_on_user_type_and_time'
  end
end
