# Lead response plays already installed check `entity.opt_in_sms` before the
# first text. That column now means marketing consent only, so their consent
# branch moves to Lead#may_text_about_inquiry, the same check new installs
# get. Only play-made rules are touched; a dealer's own workflows keep
# whatever they were built with. Runs already in flight keep their snapshot.
class PlayTextsCheckInquiryConsent < ActiveRecord::Migration[8.0]
  OLD = '"entity.opt_in_sms"'
  NEW = '"entity.may_text_about_inquiry"'

  def up
    swap(OLD, NEW)
  end

  def down
    swap(NEW, OLD)
  end

  private

  def swap(from, to)
    execute <<~SQL
      UPDATE workflow_rules
         SET steps = replace(steps::text, #{quote(from)}, #{quote(to)})::jsonb,
             updated_at = NOW()
       WHERE description LIKE 'Created by the % play.'
         AND steps::text LIKE #{quote("%#{from}%")}
    SQL
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
