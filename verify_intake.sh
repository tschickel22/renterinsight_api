set -euo pipefail

echo "== Routes =="
bin/rails routes | grep -E 'api/crm/intake/(forms|submissions)' || echo "⚠️ intake routes not found"

echo "== Tables exist? =="
bin/rails runner 'p({intake_forms: ActiveRecord::Base.connection.table_exists?(:intake_forms),
                     intake_submissions: ActiveRecord::Base.connection.table_exists?(:intake_submissions)})'

echo "== Columns (if tables/models exist) =="
bin/rails runner 'begin; puts "IntakeForm:        #{IntakeForm.columns_hash.keys.inspect}"; rescue => e; puts "IntakeForm columns? #{e.class}: #{e.message}"; end;
                  begin; puts "IntakeSubmission:  #{IntakeSubmission.columns_hash.keys.inspect}"; rescue => e; puts "IntakeSubmission columns? #{e.class}: #{e.message}"; end;'

echo "== Seed one IntakeForm (idempotent-ish) =="
bin/rails runner 'f=IntakeForm.where(name:"Contact Us").first_or_create!(description:"Basic form",
                   schema:{fields:["name","email"]}, is_active:true); puts "seeded form id=#{f.id}"'

echo "== GET endpoints (should be JSON) =="
curl -sS http://127.0.0.1:3001/api/crm/intake/forms | jq length
curl -sS http://127.0.0.1:3001/api/crm/intake/submissions | jq length
