# frozen_string_literal: true

# Adds standalone Task-model rows to workqueue_activities so Workqueue's
# task queues surface tasks created via TaskCenter's "New Task" button —
# not just tasks recorded as lead/contact/deal/account activities.
#
# Task columns don't 1:1 match the activity tables:
#   - Task.title      → subject
#   - Task.status     → integer enum, mapped to text ('pending'/'in_progress'/…)
#   - Task.priority   → integer enum, mapped to text ('low'/'medium'/…)
#   - Task.taskable_* → parent_type/parent_id (nullable for standalone tasks)
#   - Task has no user_id, start_time, end_time, reminder_time — set NULL
#
# Down restores the pre-Task 4-branch view.
class AddTasksToWorkqueueActivitiesView < ActiveRecord::Migration[8.0]
  def up
    # DROP + CREATE (not CREATE OR REPLACE) because PostgreSQL's
    # CREATE OR REPLACE VIEW rejects any column-type difference,
    # including precision — the pre-existing view had start_time as
    # `timestamp(6) without time zone` and the new NULL::timestamp
    # column resolves to `timestamp without time zone` (no precision),
    # which is semantically identical but PG treats as incompatible.
    # Dropping first gives us a clean slate. The view has no dependent
    # objects, so DROP is safe.
    execute "DROP VIEW IF EXISTS workqueue_activities;"

    execute <<~SQL
      CREATE VIEW workqueue_activities AS

      -- Lead Activities
      SELECT
        ('lead-' || la.id)::text                     AS uid,
        'lead_activities'::text                      AS source_table,
        la.id                                        AS source_id,
        'Lead'::text                                 AS parent_type,
        la.lead_id                                   AS parent_id,
        l.company_id                                 AS company_id,
        l.location_id                                AS location_id,
        la.assigned_to_id::bigint                    AS assigned_to_id,
        la.user_id::bigint                           AS user_id,
        la.activity_type::text                       AS activity_type,
        la.subject::text                             AS subject,
        la.status::text                              AS status,
        la.priority::text                            AS priority,
        la.due_date                                  AS due_date,
        la.start_time                                AS start_time,
        la.end_time                                  AS end_time,
        la.completed_at                              AS completed_at,
        la.reminder_time                             AS reminder_time,
        la.created_at                                AS created_at,
        la.updated_at                                AS updated_at
      FROM lead_activities la
      INNER JOIN leads l ON l.id = la.lead_id

      UNION ALL

      -- Contact Activities
      SELECT
        ('contact-' || ca.id)::text                  AS uid,
        'contact_activities'::text                   AS source_table,
        ca.id                                        AS source_id,
        'Contact'::text                              AS parent_type,
        ca.contact_id                                AS parent_id,
        c.company_id                                 AS company_id,
        c.location_id                                AS location_id,
        ca.assigned_to_id::bigint                    AS assigned_to_id,
        ca.user_id::bigint                           AS user_id,
        ca.activity_type::text                       AS activity_type,
        ca.subject::text                             AS subject,
        ca.status::text                              AS status,
        ca.priority::text                            AS priority,
        ca.due_date                                  AS due_date,
        ca.start_time                                AS start_time,
        ca.end_time                                  AS end_time,
        ca.completed_at                              AS completed_at,
        ca.reminder_time                             AS reminder_time,
        ca.created_at                                AS created_at,
        ca.updated_at                                AS updated_at
      FROM contact_activities ca
      INNER JOIN contacts c ON c.id = ca.contact_id
      WHERE c.is_deleted IS NOT TRUE

      UNION ALL

      -- Deal Activities (different column names — normalize)
      SELECT
        ('deal-' || da.id)::text                     AS uid,
        'deal_activities'::text                      AS source_table,
        da.id                                        AS source_id,
        'Deal'::text                                 AS parent_type,
        da.deal_id                                   AS parent_id,
        d.company_id                                 AS company_id,
        d.location_id                                AS location_id,
        da.assigned_to_id::bigint                    AS assigned_to_id,
        da.user_id::bigint                           AS user_id,
        da.activity_type::text                       AS activity_type,
        da.subject::text                             AS subject,
        da.status::text                              AS status,
        da.priority::text                            AS priority,
        da.due_date                                  AS due_date,
        da.start_time                                AS start_time,
        da.end_time                                  AS end_time,
        da.completed_at                              AS completed_at,
        da.reminder_time                             AS reminder_time,
        da.created_at                                AS created_at,
        da.updated_at                                AS updated_at
      FROM deal_activities da
      INNER JOIN deals d ON d.id = da.deal_id
      WHERE d.deleted_at IS NULL

      UNION ALL

      -- Account Activities (has both old and new columns — use new ones)
      SELECT
        ('account-' || aa.id)::text                  AS uid,
        'account_activities'::text                   AS source_table,
        aa.id                                        AS source_id,
        'Account'::text                              AS parent_type,
        aa.account_id                                AS parent_id,
        a.company_id                                 AS company_id,
        a.location_id                                AS location_id,
        aa.assigned_to_id::bigint                    AS assigned_to_id,
        aa.user_id::bigint                           AS user_id,
        aa.activity_type::text                       AS activity_type,
        aa.subject::text                             AS subject,
        aa.status::text                              AS status,
        aa.priority::text                            AS priority,
        aa.due_date                                  AS due_date,
        aa.start_time                                AS start_time,
        aa.end_time                                  AS end_time,
        aa.completed_at                              AS completed_at,
        aa.reminder_time                             AS reminder_time,
        aa.created_at                                AS created_at,
        aa.updated_at                                AS updated_at
      FROM account_activities aa
      INNER JOIN accounts a ON a.id = aa.account_id
      WHERE a.is_deleted IS NOT TRUE

      UNION ALL

      -- Standalone Tasks (from the tasks table — created via TaskCenter's
      -- "New Task" button). Task uses integer enums for status/priority
      -- and a polymorphic taskable_ association that may be NULL for
      -- tasks not tied to a specific record.
      SELECT
        ('task-' || t.id)::text                      AS uid,
        'tasks'::text                                AS source_table,
        t.id                                         AS source_id,
        t.taskable_type::text                        AS parent_type,
        t.taskable_id                                AS parent_id,
        t.company_id                                 AS company_id,
        t.location_id                                AS location_id,
        t.assigned_to_id::bigint                     AS assigned_to_id,
        NULL::bigint                                 AS user_id,
        'task'::text                                 AS activity_type,
        t.title::text                                AS subject,
        (CASE t.status
           WHEN 0 THEN 'pending'
           WHEN 1 THEN 'in_progress'
           WHEN 2 THEN 'on_hold'
           WHEN 3 THEN 'completed'
           WHEN 4 THEN 'cancelled'
           ELSE NULL
         END)::text                                  AS status,
        (CASE t.priority
           WHEN 0 THEN 'low'
           WHEN 1 THEN 'medium'
           WHEN 2 THEN 'high'
           WHEN 3 THEN 'urgent'
           ELSE NULL
         END)::text                                  AS priority,
        t.due_date                                   AS due_date,
        NULL::timestamp(6) without time zone         AS start_time,
        NULL::timestamp(6) without time zone         AS end_time,
        t.completed_at                               AS completed_at,
        NULL::timestamp(6) without time zone         AS reminder_time,
        t.created_at                                 AS created_at,
        t.updated_at                                 AS updated_at
      FROM tasks t
      ;
    SQL
  end

  def down
    # Same DROP + CREATE pattern as `up` — rollback needs to change the
    # view's column set (removing the tasks branch), and CREATE OR
    # REPLACE would fail if any column type differs.
    execute "DROP VIEW IF EXISTS workqueue_activities;"

    execute <<~SQL
      CREATE VIEW workqueue_activities AS

      SELECT
        ('lead-' || la.id)::text                     AS uid,
        'lead_activities'::text                      AS source_table,
        la.id                                        AS source_id,
        'Lead'::text                                 AS parent_type,
        la.lead_id                                   AS parent_id,
        l.company_id                                 AS company_id,
        l.location_id                                AS location_id,
        la.assigned_to_id::bigint                    AS assigned_to_id,
        la.user_id::bigint                           AS user_id,
        la.activity_type::text                       AS activity_type,
        la.subject::text                             AS subject,
        la.status::text                              AS status,
        la.priority::text                            AS priority,
        la.due_date                                  AS due_date,
        la.start_time                                AS start_time,
        la.end_time                                  AS end_time,
        la.completed_at                              AS completed_at,
        la.reminder_time                             AS reminder_time,
        la.created_at                                AS created_at,
        la.updated_at                                AS updated_at
      FROM lead_activities la
      INNER JOIN leads l ON l.id = la.lead_id

      UNION ALL

      SELECT
        ('contact-' || ca.id)::text                  AS uid,
        'contact_activities'::text                   AS source_table,
        ca.id                                        AS source_id,
        'Contact'::text                              AS parent_type,
        ca.contact_id                                AS parent_id,
        c.company_id                                 AS company_id,
        c.location_id                                AS location_id,
        ca.assigned_to_id::bigint                    AS assigned_to_id,
        ca.user_id::bigint                           AS user_id,
        ca.activity_type::text                       AS activity_type,
        ca.subject::text                             AS subject,
        ca.status::text                              AS status,
        ca.priority::text                            AS priority,
        ca.due_date                                  AS due_date,
        ca.start_time                                AS start_time,
        ca.end_time                                  AS end_time,
        ca.completed_at                              AS completed_at,
        ca.reminder_time                             AS reminder_time,
        ca.created_at                                AS created_at,
        ca.updated_at                                AS updated_at
      FROM contact_activities ca
      INNER JOIN contacts c ON c.id = ca.contact_id
      WHERE c.is_deleted IS NOT TRUE

      UNION ALL

      SELECT
        ('deal-' || da.id)::text                     AS uid,
        'deal_activities'::text                      AS source_table,
        da.id                                        AS source_id,
        'Deal'::text                                 AS parent_type,
        da.deal_id                                   AS parent_id,
        d.company_id                                 AS company_id,
        d.location_id                                AS location_id,
        da.assigned_to_id::bigint                    AS assigned_to_id,
        da.user_id::bigint                           AS user_id,
        da.activity_type::text                       AS activity_type,
        da.subject::text                             AS subject,
        da.status::text                              AS status,
        da.priority::text                            AS priority,
        da.due_date                                  AS due_date,
        da.start_time                                AS start_time,
        da.end_time                                  AS end_time,
        da.completed_at                              AS completed_at,
        da.reminder_time                             AS reminder_time,
        da.created_at                                AS created_at,
        da.updated_at                                AS updated_at
      FROM deal_activities da
      INNER JOIN deals d ON d.id = da.deal_id
      WHERE d.deleted_at IS NULL

      UNION ALL

      SELECT
        ('account-' || aa.id)::text                  AS uid,
        'account_activities'::text                   AS source_table,
        aa.id                                        AS source_id,
        'Account'::text                              AS parent_type,
        aa.account_id                                AS parent_id,
        a.company_id                                 AS company_id,
        a.location_id                                AS location_id,
        aa.assigned_to_id::bigint                    AS assigned_to_id,
        aa.user_id::bigint                           AS user_id,
        aa.activity_type::text                       AS activity_type,
        aa.subject::text                             AS subject,
        aa.status::text                              AS status,
        aa.priority::text                            AS priority,
        aa.due_date                                  AS due_date,
        aa.start_time                                AS start_time,
        aa.end_time                                  AS end_time,
        aa.completed_at                              AS completed_at,
        aa.reminder_time                             AS reminder_time,
        aa.created_at                                AS created_at,
        aa.updated_at                                AS updated_at
      FROM account_activities aa
      INNER JOIN accounts a ON a.id = aa.account_id
      WHERE a.is_deleted IS NOT TRUE
      ;
    SQL
  end
end
