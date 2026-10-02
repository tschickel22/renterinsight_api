---
name: lead-rescue
description: Find DealerTide leads that have fallen through the cracks (no activity in weeks, nothing scheduled, overdue follow-ups) and put a next step on the ones worth saving. Use when a dealer, sales manager or rep asks which leads are going cold, who is behind on follow-up, to clean up their pipeline, or to build a call list for the week.
---

# Lead rescue

Most dealers have far more open leads than anyone is working. The usual picture is
hundreds of leads in "new", "attempted to contact" or "contact in future" with no
activity for a month and nothing on anyone's calendar. This skill sizes that problem,
picks the leads most worth a call, and schedules the next step on each, with the
person's approval.

Needs the DealerTide connector. Writing (scheduling follow-ups, notes) needs a
connection that allows changes.

## 1. Size it before listing anyone

Call `get_reference_data` for status keys and people, then `lead_follow_up_gaps`
(quiet_days 14 unless the person says otherwise). Report in a few lines:

- open leads, how many are quiet, how many have no next step, how many follow-ups are overdue
- the owners with the most leads and nothing scheduled
- the statuses holding the most quiet leads

If the person is a rep, pass owner "me". If they manage a team, show the per-owner
table and ask whether to work one person's leads or the whole store.

## 2. Pick who to call

Pull candidates with `list_leads` using `no_follow_up: true` and `quiet_days`, one
status at a time, in this order unless the person says otherwise:

1. Late-stage statuses (engaged, showing scheduled, proposal, negotiation,
   application submitted). Few leads, highest value. Take all of them.
2. "Replied" or "call back" style statuses. The customer reached out; nobody answered.
3. New leads quiet more than 3 days. Speed matters most here.
4. Contacted and attempted to contact.
5. Contact in future. Usually the largest pile. Only the ones whose notes mention a
   timeframe that has now arrived (fetch a handful and read the notes before
   proposing them).

Unassigned leads always get called out separately: they need an owner before a
follow-up means anything. Offer `assign_lead`.

Stop at a list the person can actually work: 15 to 25 leads for one rep for a week,
not 200. Each `list_leads` call returns at most 50 and counts against a daily record
budget, so do not page through the whole book.

For each lead you propose, `fetch` it and give one line: who, what they wanted (home
type, budget, timeframe), the last touch and when, and the specific next step
("call, she asked about the 16x80 in August and said after school starts").
Never invent interest the record does not show.

## 3. Schedule, with approval

Show the list as a table and ask which to schedule. Then for each approved lead call
`add_lead_follow_up` with:

- a subject that says what to do and why, not "Follow up"
- a due date spread across the coming days (no more than 8 to 10 per rep per day)
- kind "call" for phone follow-ups, "task" otherwise
- no assignee, so it goes to the lead's owner, unless the person says otherwise

Writes are limited to about 30 an hour per person. If the list is longer, schedule
the most valuable first and tell the person where you stopped.

Offer, never assume:

- `add_note` with what you found, when the record is missing context the rep will need
- `update_lead_status` to a closed status for leads that are clearly dead (the notes
  say bought elsewhere, wrong number, not interested). Ask for each one; closing a
  lead is a judgment call for the dealer.
- `enroll_in_nurture` for leads that are not ready to buy, if the dealer has a
  long-term sequence (`list_nurture_sequences`).

## 4. Finish

Summarize what was scheduled (count per person, date range), what was skipped and
why, and the leads that still need an owner. Include links.

## Rules

- Confirm before every change. Show what will be written.
- Do not draft or send messages to customers unless asked. If asked, write plainly,
  never use em dashes or en dashes, and remind the person that sending happens in
  DealerTide.
- If a lead has opted out or is marked do not contact, leave it alone.
- If `lead_follow_up_gaps` shows almost nothing quiet, say so and stop. Do not
  manufacture work.
