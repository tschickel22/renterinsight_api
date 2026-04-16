# frozen_string_literal: true

class CreateWorkqueueActivitiesView < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE OR REPLACE VIEW workqueue_activities AS

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
      ;
    SQL
  end

  def down
    execute "DROP VIEW IF EXISTS workqueue_activities;"
  end
end
