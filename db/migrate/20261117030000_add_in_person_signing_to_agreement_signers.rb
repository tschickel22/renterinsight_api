# A signature taken on the dealer's own screen at the desk, told apart from one the
# customer made at home: who handed the screen over, and a short window that the
# authenticated Sign Now action opens on the signer. The public signing endpoint has
# no session, so the window (not the browser) is what says a signature was taken in
# person; a client cannot claim it.
class AddInPersonSigningToAgreementSigners < ActiveRecord::Migration[8.0]
  def change
    add_column :agreement_signers, :signed_in_person, :boolean, default: false, null: false
    add_column :agreement_signers, :hosted_by_user_id, :bigint
    add_column :agreement_signers, :in_person_until, :datetime
    add_index :agreement_signers, :hosted_by_user_id
  end
end
