# `ocr_requested_at`: when the app last queued ReceiptOcrJob for the receipt, nil when no request is waiting
# (docs/domain.md, "Who enqueues OCR"). Receipts::RequestOcr sets it with one conditional UPDATE, so two
# requests for the same receipt (the page opened twice, "Read again" clicked twice) queue one job; the job
# clears it when it starts. It also records that a person asked to read an `extracted` receipt again: the
# job re-reads an `extracted` receipt only while this is set.
#
# Nullable with no default, so existing rows stay valid and mean "no request waiting".
class AddOcrRequestedAtToReceipts < ActiveRecord::Migration[8.1]
  def change
    add_column :receipts, :ocr_requested_at, :timestamptz
  end
end
