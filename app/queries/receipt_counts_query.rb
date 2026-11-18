# How far the receipts have come: how many are stored, per status, how many OCR has read, and how many
# have ground truth. Every receipt counts, whatever its date: these are the state of the receipt pipeline,
# not money, so there is no period and no currency.
#
# - `total`: every stored receipt (loaded by the receipt load or uploaded in the app);
# - `by_status`: every status of Receipt.statuses, in its life-cycle order, with 0 where none is;
#   `reviewed` is a receipt accepted into the ledger, `extracted` one read and waiting for review;
# - `read_by_ocr`: receipts OCR has read at least once (`ocr_model_name` is set by Receipts::ApplyOcr and
#   kept afterwards). A receipt a person entered by hand without an OCR read is not one;
# - `with_ground_truth`: receipts with at least one ReceiptGroundTruth record (any source).
#
# One query.
class ReceiptCountsQuery
  Counts = Data.define(:total, :by_status, :read_by_ocr, :with_ground_truth)

  def call
    rows = Receipt.group(:status).pluck(
      :status,
      Arel.sql("COUNT(*)"),
      Arel.sql("COUNT(*) FILTER (WHERE receipts.ocr_model_name IS NOT NULL)"),
      Arel.sql("COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM receipt_ground_truths WHERE receipt_ground_truths.receipt_id = receipts.id))")
    )
    by_status = Receipt.statuses.keys.index_with(0)
    rows.each { |status, count, _, _| by_status[status] = count }

    Counts.new(
      total: rows.sum { |row| row[1] },
      by_status:,
      read_by_ocr: rows.sum { |row| row[2] },
      with_ground_truth: rows.sum { |row| row[3] }
    )
  end
end
