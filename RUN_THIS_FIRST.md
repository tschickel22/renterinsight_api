# QUICK FIX - Run Migration

## The problem is simple: the database table doesn't exist yet!

You need to run the migration. Choose ONE of these methods:

---

## Method 1: From WSL Terminal (RECOMMENDED)

1. Open WSL terminal
2. Run these commands:

```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails db:migrate
```

3. You should see output like:
```
== 20251008000001 CreateLeadActivities: migrating ============================
-- create_table(:lead_activities)
   -> 0.0234s
== 20251008000001 CreateLeadActivities: migrated (0.0235s) ===================
```

4. Restart your Rails server (Ctrl+C, then `bundle exec rails s -p 3001`)

---

## Method 2: From Windows (if you're not in WSL)

1. Open Command Prompt or PowerShell
2. Navigate to the project folder
3. Run:

```bash
wsl bash -c "cd /home/tschi/src/renterinsight_api && bundle exec rails db:migrate"
```

4. Restart your Rails server

---

## Method 3: Use the script

1. Open WSL terminal
2. Run:

```bash
cd /home/tschi/src/renterinsight_api
chmod +x run_migration.sh
./run_migration.sh
```

---

## How to verify it worked:

Run this command:
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails runner "puts ActiveRecord::Base.connection.table_exists?('lead_activities') ? 'SUCCESS - Table exists!' : 'FAILED - Table not found'"
```

If you see "SUCCESS - Table exists!" then you're good to go!

---

## After the migration is successful:

1. **RESTART YOUR RAILS SERVER** (this is critical!)
2. Refresh your browser
3. Navigate to a lead and click the "Activities" tab
4. Try creating a task

---

## Still having issues?

Run this to see all tables in your database:
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails runner "puts ActiveRecord::Base.connection.tables.sort.join('\n')"
```

If you see `lead_activities` in the list, the migration worked. If not, something went wrong with the migration.
