# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GuideDigestMailer do
  it 'lists the week, the help to review, new tours and the tours waiting for approval' do
    snap = Knowledge::Snapshot.create!(source: 'frontend', snapshot_at: Time.current, modules_hash: 'x')
    release = snap.change_queue_items.create!(
      change_type: 'modified', entity_type: 'release', entity_key: 'week-2026-10-12', draft_status: 'drafted',
      context: { 'weekly' => true, 'week' => '2026-10-12', 'commits' => [{ 'sha' => 'a' }], 'changes' => [] },
      drafts: { 'user_facing' => true, 'title' => 'Cash flow', 'notes' => '- New report', 'skipped' => [{ 'what' => 'Admin page', 'why' => 'admin only' }] }
    )
    snap.change_queue_items.create!(
      change_type: 'added', entity_type: 'atlas_entry', entity_key: 'report:cash-flow', draft_status: 'drafted',
      new_value: { 'title' => 'Cash Flow' }, context: { 'weekly' => true, 'week' => '2026-10-12' },
      drafts: { 'tour' => { 'name' => 'Where to find Cash Flow', 'steps' => [{ 'selector' => 'x' }] } }
    )
    Tour.create!(key: 'unapproved-tour', name: 'Add your first lead', trigger_type: 'manual', is_active: true)

    mail = described_class.weekly(release.id)
    text = mail.text_part.body.to_s

    expect(mail.to).to eq([Guide::WeeklyDigest.recipient])
    expect(mail.subject).to include('week of 2026-10-12', '1 to review')
    expect(text).to include('Cash flow', 'Cash Flow: new, new tour drafted', 'Where to find Cash Flow', 'Add your first lead', 'Admin page: admin only')
    expect(mail.html_part.body.to_s).to include('/admin/knowledge')
  end
end
