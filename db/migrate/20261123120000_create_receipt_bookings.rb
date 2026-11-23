# The record of a receipt's booking (docs/decisions/0018-link-receipt-to-transaction.md, docs/domain.md
# "Receipt bookings"): one row per booked receipt, written by Receipts::Accept, so that a booking can be undone.
#
# - receipt_id, transaction_id: one row per receipt and per transaction. Both cascade: when the importer
#   destroys a row to replace it, its record goes with it (and Transaction#release_receipt sends the receipt
#   back to `extracted`); a record never outlives what it describes.
# - mode: `linked` (the person chose a transaction already in the ledger, whose lines Accept replaced) or
#   `created` (Accept created a new expense).
# - previous: for `linked`, the transaction as it was before the first rebook (format version, amount as a
#   decimal string, status, payee_id, every column of every old line), so an undo can put it back; null for
#   `created`. Written at the first link only.
# - lines_digest: SHA-256 of the lines Accept wrote, in a canonical form (ReceiptBooking.lines_digest),
#   refreshed by every "Accept again": an undo compares it with the lines stored then.
# - transaction_import_digest: the transaction's import_digest at the first link (null when no importer wrote
#   the row), so an undo can tell that an import rewrote the row since.
# - booked_lock_version: the transaction's lock_version right after Accept wrote it (refreshed by every "Accept
#   again"): every writer of the row or its lines moves it, so an undo can tell that a person changed the
#   transaction since (its payee, a comment, a category).
# - assigned_payee_id, payee_created: the payee Accept set on the transaction (null when it set none), and
#   whether Accept created that payee.
#
# Rolling back drops the table, and with it the only copy of the earlier state of every linked transaction: the
# rollback refuses while the table has a row.
class CreateReceiptBookings < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_bookings do |t|
      t.references :receipt, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :transaction, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :mode, null: false
      t.jsonb :previous
      t.string :lines_digest, null: false
      t.string :transaction_import_digest
      t.integer :booked_lock_version, null: false
      t.references :assigned_payee, foreign_key: { to_table: :payees }
      t.boolean :payee_created, null: false, default: false
      t.timestamps

      t.check_constraint "mode IN ('linked', 'created')", name: "receipt_bookings_mode_allowed"
      t.check_constraint "mode <> 'created' OR (previous IS NULL AND transaction_import_digest IS NULL)",
        name: "receipt_bookings_created_shape"
      # IS TRUE: a missing key (or a null `previous`) makes jsonb_typeof null, which a check would let through.
      t.check_constraint "mode <> 'linked' OR (jsonb_typeof(previous) = 'object' AND jsonb_typeof(previous -> 'format') = 'number' " \
        "AND jsonb_typeof(previous -> 'amount') = 'string' AND jsonb_typeof(previous -> 'status') = 'string' " \
        "AND jsonb_typeof(previous -> 'lines') = 'array') IS TRUE",
        name: "receipt_bookings_linked_shape"
      t.check_constraint "lines_digest ~ '^[0-9a-f]{64}$'", name: "receipt_bookings_lines_digest_format"
      t.check_constraint "NOT payee_created OR assigned_payee_id IS NOT NULL", name: "receipt_bookings_created_payee_assigned"
      t.check_constraint "booked_lock_version >= 0", name: "receipt_bookings_booked_lock_version_not_negative"
    end

    # Runs first on a rollback (reversed order), before the table is dropped.
    reversible do |direction|
      direction.down do
        count = select_value("SELECT COUNT(*) FROM receipt_bookings").to_i
        if count.positive?
          raise ActiveRecord::IrreversibleMigration, "receipt_bookings holds #{count} booking record(s), the only copy of " \
            "the earlier state of the transactions receipts were booked onto; undo or keep them before rolling back"
        end
      end
    end
  end
end
