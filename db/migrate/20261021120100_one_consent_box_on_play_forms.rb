# frozen_string_literal: true

# Forms a play created carried their own "Text Me" SMS box beside the consent
# box every form draws, so visitors were asked twice. The built-in box ("email
# and text me") already sets opt_in_sms, which is all the play checks, so the
# play's own box is removed and the built-in one turned on.
#
# The same forms named whoever turned the play on as their notified user, even
# a platform admin from another company signed in as the dealer. That person
# owned every lead from the form and was emailed about it. Cleared here; the
# form falls back to the play's rotation.
#
# Only forms a play made, found by the description every one of them carries.
class OneConsentBoxOnPlayForms < ActiveRecord::Migration[8.0]
  PLAY_FORMS = "description LIKE 'Created by the % play.'"

  def up
    execute <<~SQL
      UPDATE intake_forms f
         SET schema = (
               SELECT COALESCE(jsonb_agg(e ORDER BY ord), '[]'::jsonb)
                 FROM jsonb_array_elements(f.schema::jsonb) WITH ORDINALITY t(e, ord)
                WHERE NOT (e->>'name' = 'Text Me' AND e->>'leadField' = 'opt_in_sms')
             )::json,
             field_mappings = (COALESCE(f.field_mappings::jsonb, '{}'::jsonb) - 'Text Me')::json,
             marketing_consent_enabled = TRUE,
             updated_at = NOW()
       WHERE f.#{PLAY_FORMS}
         AND json_typeof(f.schema) = 'array'
         AND EXISTS (
               SELECT 1 FROM jsonb_array_elements(f.schema::jsonb) e
                WHERE e->>'name' = 'Text Me' AND e->>'leadField' = 'opt_in_sms'
             )
    SQL

    execute <<~SQL
      UPDATE intake_forms f
         SET notified_user_id = NULL, updated_at = NOW()
        FROM users u
       WHERE u.id = f.notified_user_id
         AND u.company_id IS DISTINCT FROM f.company_id
         AND f.#{PLAY_FORMS}
    SQL
  end

  def down
    # The removed box and the other company's user are not put back.
  end
end
